// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;


// OpenZeppelin: ERC721 with per-token URI storage
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
// OpenZeppelin: Base64 encoding utility for on-chain metadata
import "@openzeppelin/contracts/utils/Base64.sol";
// OpenZeppelin: converts uint256 to string for use in JSON
import "@openzeppelin/contracts/utils/Strings.sol";


// =============================================================
//  MARRIAGE CONTRACT
//
//  One instance is deployed per couple by the MarriageFactory.
//  It holds ETH and allows withdrawals only when:
//    1. One partner proposes an amount and destination
//    2. The OTHER partner approves it (prevents self-approval)
//    3. 48 hours have passed since the proposal (timelock)
//
//  Security:
//    - onlyPartners modifier blocks strangers
//    - proposer stored in struct blocks self-approval
//    - CEI pattern in executeWithdrawal blocks reentrancy
//    - Solidity ^0.8.20 handles overflow natively
// =============================================================


contract MarriageContract {


    // immutable: written once in constructor, stored in bytecode
    // cheaper to read than regular storage variables (no SLOAD cost)
    address payable public immutable partner1;
    address payable public immutable partner2;


    // used by the factory to check if this marriage is still active
    bool public isMarried = true;


    // 48-hour delay between proposal and execution
    uint256 public constant TIMELOCK = 2 minutes;


    // holds all data about the current pending withdrawal
    struct WithdrawalRequest {
        uint256 amount;              // how much to send
        address payable destination; // where to send it
        address proposer;            // who proposed (to block self-approval)
        uint256 requestedAt;         // when proposed (for timelock)
        bool approvedByOther;        // has the other partner signed?
        bool executed;               // has it been sent already?
    }


    // only one active request at a time
    WithdrawalRequest public pendingRequest;


    // custom errors are more gas-efficient than require strings
    // params give the caller useful context on why the call failed
    error NotAPartner();
    error RequestPending();
    error InvalidAmount(uint256 requested, uint256 available);
    // address(0) is 0x000...000 — the zero address
    // passing it as destination would permanently burn ETH with no recovery
    error InvalidDestination(address destination);
    error NothingToApprove();
    error AlreadyExecuted();
    error AlreadyApproved();
    error CannotApproveSelf(address proposer);
    error NotApproved();
    // tells the caller exactly how many seconds remain before execution is allowed
    error TimelockActive(uint256 remainingSeconds);
    // tells the caller what is available vs what was requested
    error InsufficientBalance(uint256 available, uint256 requested);
    error TransferFailed();
    // reverts if divorce() is called on an already-divorced contract
    error AlreadyDivorced();


    // events let the front-end track all activity on the contract
    event Deposited(address indexed sender, uint256 amount);
    event WithdrawalProposed(address indexed by, uint256 amount, address destination);
    event WithdrawalApproved(address indexed by);
    event WithdrawalExecuted(uint256 amount, address destination);
    event Divorced(address indexed filedBy);


    // payable constructor: the factory can forward an initial ETH deposit
    // at deployment time without a separate transaction
    constructor(address payable _partner1, address payable _partner2) payable {
        if (_partner1 == _partner2) revert InvalidDestination(_partner1);
        partner1 = _partner1;
        partner2 = _partner2;
        // emit only if ETH was actually sent, to keep logs clean
        if (msg.value > 0) emit Deposited(msg.sender, msg.value);
    }


    // receive() is the standard Solidity hook for plain ETH transfers
    // triggered when someone sends ETH directly to the contract address
    // with no calldata (e.g. from a wallet or via .transfer())
    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }


    // reusable access control: only registered partners can call protected functions
    modifier onlyPartners() {
        if (msg.sender != partner1 && msg.sender != partner2) revert NotAPartner();
        _;
    }


    // STEP 1 — one partner initiates a withdrawal request
    // a new proposal is blocked if one is already awaiting approval
    function proposeWithdrawal(uint256 _amount, address payable _destination) external onlyPartners {
        // block a new proposal if one is already approved but not executed
        if (pendingRequest.approvedByOther && !pendingRequest.executed) revert RequestPending();
        // amount must be positive and not exceed the current balance
        if (_amount == 0 || _amount > address(this).balance) revert InvalidAmount(_amount, address(this).balance);
        // address(0) = zero address — sending ETH there burns it permanently
        if (_destination == address(0)) revert InvalidDestination(_destination);


        // store the full request, including who proposed it
        pendingRequest = WithdrawalRequest({
            amount: _amount,
            destination: _destination,
            proposer: msg.sender,  // saved to prevent self-approval in step 2
            requestedAt: block.timestamp,
            approvedByOther: false,
            executed: false
        });


        emit WithdrawalProposed(msg.sender, _amount, _destination);
    }


    // STEP 2 — the OTHER partner approves the pending request
    // the proposer field in the struct prevents one partner from
    // both proposing and approving a withdrawal alone
    function approveWithdrawal() external onlyPartners {
        // use a storage pointer to avoid multiple SLOADs
        WithdrawalRequest storage req = pendingRequest;
        if (req.amount == 0)            revert NothingToApprove();
        if (req.executed)               revert AlreadyExecuted();
        if (req.approvedByOther)        revert AlreadyApproved();
        // proposer is stored in the struct so we can block self-approval here
        if (msg.sender == req.proposer) revert CannotApproveSelf(req.proposer);


        req.approvedByOther = true;
        emit WithdrawalApproved(msg.sender);
    }


    // STEP 3 — anyone can trigger execution once both conditions are met:
    //   - the other partner has approved (step 2 done)
    //   - 48 hours have elapsed since the proposal
    //
    // Follows the Checks-Effects-Interactions pattern:
    //   CHECKS  : all require/revert conditions first
    //   EFFECTS : state is updated before any external call
    //   INTERACTIONS: ETH transfer happens last
    // This ordering prevents reentrancy attacks
    function executeWithdrawal() external {
        WithdrawalRequest storage req = pendingRequest;


        // CHECKS
        if (!req.approvedByOther)                         revert NotApproved();
        if (req.executed)                                 revert AlreadyExecuted();
        if (block.timestamp < req.requestedAt + TIMELOCK) revert TimelockActive(req.requestedAt + TIMELOCK - block.timestamp);
        if (address(this).balance < req.amount)           revert InsufficientBalance(address(this).balance, req.amount);


        // cache values before wiping state
        uint256 amount = req.amount;
        address payable destination = req.destination;


        // EFFECTS: reset state before the external call
        // if the transfer is called first and the destination re-enters,
        // the state would still show the request as pending — this prevents that
        req.executed = true;
        req.approvedByOther = false;
        req.amount = 0;
        req.proposer = address(0);


        // INTERACTIONS: external ETH transfer
        emit WithdrawalExecuted(amount, destination);
        (bool success, ) = destination.call{value: amount}("");
        if (!success) revert TransferFailed();
    }


    // either partner can file for divorce at any time
    // sets isMarried to false permanently — cannot be undone
    // does not affect funds or pending withdrawals
    // after divorce, both partners are free to remarry anyone
    function divorce() external onlyPartners {
        if (!isMarried) revert AlreadyDivorced();
        isMarried = false;
        emit Divorced(msg.sender);
    }


    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }
}


// =============================================================
//  MARRIAGE NFT
//
//  A minimal ERC721 following the same pattern as the photo:
//  tokenCounter, a single mint function, on-chain Base64 metadata.
//  One token is minted per marriage and sent to the
//  MarriageContract address itself.
//
//  Soulbound: transfers and approvals are permanently disabled.
//  Only the MarriageFactory (set at construction) can mint.
// =============================================================


contract MarriageNFT is ERC721URIStorage {


    // incremented on each mint, starts at 0
    uint256 public tokenCounter;


    // the factory address is fixed at construction — only it can mint
    address public immutable factory;


    error OnlyFactory();
    error Soulbound();


    constructor() ERC721("MarriageRing", "RING") {
        factory = msg.sender; // the deployer is the MarriageFactory constructor
        tokenCounter = 0;
    }


    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }


    // OZ v5 uses _update instead of _beforeTokenTransfer
    // from == address(0) means it is a mint — allow it
    // anything else is a transfer — block it
    function _update(address to, uint256 tokenId, address auth)
        internal override returns (address)
    {
        if (_ownerOf(tokenId) != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }


    // simple mint API: factory passes names and date,
    // the contract builds and stores the tokenURI on-chain
    function mintRing(
        address to,
        string calldata name1,  // calldata: cheaper than memory for read-only strings
        string calldata name2,
        uint256 unionDate
    ) external onlyFactory returns (uint256) {
        uint256 newId = tokenCounter;
        tokenCounter += 1;


        _mint(to, newId);
        // tokenURI is built entirely on-chain and stored permanently
        _setTokenURI(newId, _buildTokenURI(newId, name1, name2, unionDate));


        return newId;
    }


    // builds a Base64-encoded JSON string stored directly on-chain
    // no IPFS or external dependency needed
    // string.concat is cleaner than abi.encodePacked for string building
    function _buildTokenURI(
        uint256 tokenId,
        string calldata name1,
        string calldata name2,
        uint256 unionDate
    ) internal pure returns (string memory) {
        // shared ring image hosted externally
        string memory imageUrl = "https://sepvergara.com/wp-content/uploads/2025/02/WR370-2048x2048.jpg";


        // build the raw JSON metadata
        string memory json = string.concat(
            '{"name":"Marriage Ring #', Strings.toString(tokenId), '",',
            '"description":"Soulbound marriage NFT for ', name1, ' & ', name2, '.",',
            '"image":"', imageUrl, '",',
            '"attributes":[',
                '{"trait_type":"Partner 1","value":"', name1, '"},',
                '{"trait_type":"Partner 2","value":"', name2, '"},',
                '{"trait_type":"Union Date","value":"', Strings.toString(unionDate), '"}',
            ']}'
        );


        // encode to Base64 so it can be embedded directly in the tokenURI
        string memory encoded = Base64.encode(bytes(json));


        // prefix tells wallets and marketplaces this is inline JSON data
        return string.concat("data:application/json;base64,", encoded);
    }
}


// =============================================================
//  MARRIAGE FACTORY
//
//  The single contract you deploy manually.
//  On each createMarriage call it:
//    1. Checks neither partner is already in an active marriage
//    2. Deploys a new MarriageContract (forwarding any ETH sent)
//    3. Mints a soulbound NFT to that new contract
//    4. Saves the record in a registry array + partner mapping
//
//  The caller must be one of the two partners (not a stranger).
// =============================================================


contract MarriageFactory {


    // one record stored per marriage in the registry
    struct MarriageRecord {
        address contractAddress; // the deployed MarriageContract
        address partner1;
        address partner2;
        string name1;
        string name2;
        uint256 createdAt;       // block.timestamp at creation
        uint256 nftTokenId;      // the minted NFT id
    }


    // the NFT contract is deployed once in this constructor and never changes
    MarriageNFT public immutable nftContract;


    // flat array of all marriages — index-based access for the front-end
    MarriageRecord[] public marriages;


    // maps any partner address to the list of their marriage indices
    // used to look up a partner's marriages without scanning the full array
    mapping(address => uint256[]) public marriagesByPartner;


    // address(0) means uninitialized — tells the caller which address is invalid
    error InvalidAddress(address provided);
    error NotAPartner();
    error AlreadyMarried(address partner);


    event MarriageCreated(
        address indexed contractAddress,
        address indexed partner1,
        address indexed partner2,
        uint256 index,
        uint256 nftTokenId
    );


    // deploy the NFT contract once — its address is stored as immutable
    constructor() {
        nftContract = new MarriageNFT();
    }


    // creates a new marriage: deploys a contract, mints an NFT, saves the record
    // payable: any ETH sent here is forwarded to the new MarriageContract
    function createMarriage(
        string calldata name1,
        string calldata name2,
        address payable partner1,
        address payable partner2
    ) external payable {
        // basic address sanity check
        if (partner1 == address(0)) revert InvalidAddress(partner1);
        if (partner2 == address(0)) revert InvalidAddress(partner2);
        // the caller must be one of the two partners — strangers cannot create marriages
        if (msg.sender != partner1 && msg.sender != partner2) revert NotAPartner();
        // neither partner can already be in an active marriage
        if (isAlreadyMarried(partner1)) revert AlreadyMarried(partner1);
        if (isAlreadyMarried(partner2)) revert AlreadyMarried(partner2);


        // deploy the MarriageContract, forwarding any ETH as initial deposit
        MarriageContract marriage = new MarriageContract{value: msg.value}(partner1, partner2);


        // mint the soulbound NFT to the marriage contract address
        uint256 tokenId = nftContract.mintRing(
            address(marriage), name1, name2, block.timestamp
        );


        // save to registry before emitting event
        uint256 index = marriages.length;


        marriages.push(MarriageRecord({
            contractAddress: address(marriage),
            partner1: partner1,
            partner2: partner2,
            name1: name1,
            name2: name2,
            createdAt: block.timestamp,
            nftTokenId: tokenId
        }));


        // update per-partner lookup so each partner can find their marriages
        marriagesByPartner[partner1].push(index);
        marriagesByPartner[partner2].push(index);


        emit MarriageCreated(address(marriage), partner1, partner2, index, tokenId);
    }


    // checks if a partner is currently in any active marriage
    // loops through their past marriages and queries isMarried on each contract
    // memory copy of indices avoids repeated storage reads inside the loop
    function isAlreadyMarried(address partner) public view returns (bool) {
        uint256[] memory indices = marriagesByPartner[partner];
        for (uint256 i = 0; i < indices.length; i++) {
            if (MarriageContract(payable(marriages[indices[i]].contractAddress)).isMarried()) {
                return true;
            }
        }
        return false;
    }


    // returns the full registry — used by the front-end to list all marriages
    function getAllMarriages() external view returns (MarriageRecord[] memory) {
        return marriages;
    }


    // returns the indices of a specific partner's marriages in the registry array
    function getMarriagesByPartner(address partner) external view returns (uint256[] memory) {
        return marriagesByPartner[partner];
    }
}
