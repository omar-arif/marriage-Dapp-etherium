# Marriage DApp - Ethereum

A fully on-chain marriage registry on Ethereum. Couples can register their marriage, manage a shared ETH wallet with multi-sig withdrawals, and file for divorce. Each marriage mints a **soulbound ERC721 NFT** as a permanent on-chain certificate.

## Architecture

### Smart Contracts (`marriage.sol`)

Three contracts in one file, already deployed on-chain:

- **`MarriageFactory`** - entry point. Deploys one `MarriageContract` per couple, enforces no partner is already married, maintains a full registry via `getAllMarriages()`
- **`MarriageContract`** - one per couple. Holds shared ETH, requires both partners to approve withdrawals with a timelock. Either partner can call `divorce()` permanently
- **`MarriageNFT`** - soulbound ERC721, one ring NFT per marriage with fully on-chain Base64 metadata. Transfers permanently disabled

### Frontend (`index.html`)

Single-page app, no build step:

- **ethers.js v6**
- Connects via MetaMask (`ethers.BrowserProvider`)
- ABIs loaded from `abis/` folder (`MarriageFactory.json`, `MarriageContract.json`, `MarriageNFT.json`)
- Create marriages, view live registry with Active/Divorced status, filter your own marriages, divorce

### Server (`server.js`)

Minimal Node.js static file server. Reads `PORT` and `FACTORY_ADDRESS` from `.env` via `dotenv`.

## Project Structure

```
marriage-Dapp-etherium/
├── index.html
├── server.js
├── marriage.sol
├── abis/
│   ├── MarriageFactory.json
│   ├── MarriageContract.json
│   └── MarriageNFT.json
├── package.json
└── .env
```

## Run Locally

```bash
git clone https://github.com/omar-arif/marriage-Dapp-etherium
cd marriage-Dapp-etherium
npm install
npm start
```

Open `http://localhost:5173` and connect MetaMask.

## Environment Variables

```env
PORT=5173
FACTORY_ADDRESS=0x7Ad6245379415d2A034B1bb66c671C59C1EcBE25
```
