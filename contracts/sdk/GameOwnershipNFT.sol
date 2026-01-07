// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract GameOwnershipNFT is ERC721URIStorage, Ownable {
    uint256 public nextTokenId;
    mapping(uint256 => address) public gameContracts;

    constructor() ERC721("Vault777 Creator", "VSDK") {}

    function mint(address to, address gameContract, string memory tokenURI) external onlyOwner returns (uint256) {
        uint256 tokenId = nextTokenId;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI);
        gameContracts[tokenId] = gameContract;
        nextTokenId++;
        return tokenId;
    }
}
