import "dotenv/config";
import http from "node:http";
import { readFile } from "node:fs/promises";
import { readFileSync } from "node:fs";

const PORT            = Number(process.env.PORT || 5173);
const FACTORY_ADDRESS = process.env.FACTORY_ADDRESS;

const FactoryABI  = JSON.parse(readFileSync("./abis/MarriageFactory.json",  "utf8"));
const MarriageABI = JSON.parse(readFileSync("./abis/MarriageContract.json", "utf8"));
const NFT_ABI     = JSON.parse(readFileSync("./abis/MarriageNFT.json",      "utf8"));

function send(res, status, body, type = "text/html; charset=utf-8") {
  res.writeHead(status, { "Content-Type": type });
  res.end(body);
}

function json(res, status, data) {
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Access-Control-Allow-Origin": "*",
  });
  res.end(JSON.stringify(data));
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (req.method === "GET" && url.pathname === "/") {
    const html = await readFile(new URL("./index.html", import.meta.url));
    return send(res, 200, html, "text/html; charset=utf-8");
  }

  if (req.method === "GET" && url.pathname === "/api/abis") {
    return json(res, 200, {
      factory:        FactoryABI,
      marriage:       MarriageABI,
      nft:            NFT_ABI,
      factoryAddress: FACTORY_ADDRESS,
    });
  }

  send(res, 404, "Not found");
}).listen(PORT, () => console.log(`http://localhost:${PORT}`));
