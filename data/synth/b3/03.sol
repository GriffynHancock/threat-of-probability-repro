// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Trait-weighted NFT emissions, distributed once per season to weights present at season close.
contract SeasonEmissions {
    uint256 private constant PRECISION = 1e18;

    IERC721 public immutable nft;
    IERC20 public immutable rewardToken;
    uint256 public immutable seasonLength;
    uint256 public immutable emissionPerSeason;
    address public admin;

    uint256 public seasonStart;
    uint256 public currentSeason;
    uint256 public cumIndex;
    uint256 public totalWeight;

    mapping(uint8 => uint256) public traitWeight;
    mapping(uint256 => uint256) public tokenWeight;
    mapping(uint256 => address) public tokenOwner;

    struct Entry {
        uint256 weight;
        uint256 index;
        uint256 pending;
    }
    mapping(address => Entry) public entries;

    event TraitSet(uint8 trait, uint256 weight);
    event Entered(address indexed user, uint256 tokenId, uint256 weight);
    event Withdrawn(address indexed user, uint256 tokenId, uint256 weight);
    event Claimed(address indexed user, uint256 amount);

    constructor(IERC721 _nft, IERC20 _reward, uint256 _seasonLength, uint256 _emission) {
        require(_seasonLength > 0, "bad season");
        nft = _nft;
        rewardToken = _reward;
        seasonLength = _seasonLength;
        emissionPerSeason = _emission;
        seasonStart = block.timestamp;
        admin = msg.sender;
    }

    function setTraitWeight(uint8 trait, uint256 weight) external {
        require(msg.sender == admin, "not admin");
        traitWeight[trait] = weight;
        emit TraitSet(trait, weight);
    }

    function _settleSeason() internal {
        while (block.timestamp >= seasonStart + seasonLength) {
            if (totalWeight > 0) {
                cumIndex += (emissionPerSeason * PRECISION) / totalWeight;
            }
            seasonStart += seasonLength;
            currentSeason += 1;
        }
    }

    function _settleUser(address who) internal {
        Entry storage e = entries[who];
        e.pending += (e.weight * (cumIndex - e.index)) / PRECISION;
        e.index = cumIndex;
    }

    function enterSeason(uint256 tokenId, uint8 trait) external {
        _settleSeason();
        _settleUser(msg.sender);
        uint256 w = traitWeight[trait];
        require(w > 0, "unknown trait");
        Entry storage e = entries[msg.sender];
        e.weight += w;
        totalWeight += w;
        tokenWeight[tokenId] = w;
        tokenOwner[tokenId] = msg.sender;
        nft.transferFrom(msg.sender, address(this), tokenId);
        emit Entered(msg.sender, tokenId, w);
    }

    function withdrawToken(uint256 tokenId) external {
        require(tokenOwner[tokenId] == msg.sender, "not owner");
        _settleSeason();
        _settleUser(msg.sender);
        uint256 w = tokenWeight[tokenId];
        Entry storage e = entries[msg.sender];
        e.weight -= w;
        totalWeight -= w;
        delete tokenWeight[tokenId];
        delete tokenOwner[tokenId];
        nft.transferFrom(address(this), msg.sender, tokenId);
        emit Withdrawn(msg.sender, tokenId, w);
    }

    function claimEmissions() external {
        _settleSeason();
        _settleUser(msg.sender);
        Entry storage e = entries[msg.sender];
        uint256 amount = e.pending;
        require(amount > 0, "nothing");
        e.pending = 0;
        require(rewardToken.transfer(msg.sender, amount), "transfer failed");
        emit Claimed(msg.sender, amount);
    }
}
