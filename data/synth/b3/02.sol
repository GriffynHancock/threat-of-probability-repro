// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title Per-block points for enlisted NFTs
/// @notice Points accrue each block for every enlisted token. Enlisting grants a fixed bonus.
contract BlockPointsLedger {
    error NotOwner(uint256 tokenId);
    error NotEnlisted(uint256 tokenId);
    error InsufficientPoints(uint256 have, uint256 want);

    uint256 private constant PRECISION = 1e18;
    uint256 public constant ENLIST_BONUS = 250 * PRECISION;

    IERC721 public immutable nft;
    uint256 public immutable ratePerTokenBlock;

    mapping(address => uint256) public points;
    mapping(address => uint256) public lastBlock;
    mapping(address => uint256[]) private _enlisted;
    mapping(uint256 => uint256) private _position; // index + 1
    mapping(uint256 => address) public holderOf;

    event Enlisted(address indexed user, uint256 tokenId);
    event Delisted(address indexed user, uint256 tokenId);
    event Redeemed(address indexed user, uint256 amount);

    constructor(IERC721 _nft, uint256 _rate) {
        nft = _nft;
        ratePerTokenBlock = _rate;
    }

    function enlistedCount(address who) external view returns (uint256) {
        return _enlisted[who].length;
    }

    function _accruePoints(address who) internal {
        uint256 n = _enlisted[who].length;
        uint256 blocksElapsed = block.number - lastBlock[who];
        if (n > 0 && blocksElapsed > 0) {
            points[who] += blocksElapsed * n * ratePerTokenBlock;
        }
        lastBlock[who] = block.number;
    }

    /// @notice Take custody of a token and add it to the caller's enlisted set.
    function enlist(uint256 tokenId) external {
        _accruePoints(msg.sender);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotOwner(tokenId);
        _enlisted[msg.sender].push(tokenId);
        _position[tokenId] = _enlisted[msg.sender].length;
        holderOf[tokenId] = msg.sender;
        points[msg.sender] += ENLIST_BONUS;
        nft.transferFrom(msg.sender, address(this), tokenId);
        emit Enlisted(msg.sender, tokenId);
    }

    function delist(uint256 tokenId) external {
        _accruePoints(msg.sender);
        uint256 pos = _position[tokenId];
        if (pos == 0 || holderOf[tokenId] != msg.sender) revert NotEnlisted(tokenId);
        uint256[] storage list = _enlisted[msg.sender];
        uint256 last = list[list.length - 1];
        list[pos - 1] = last;
        _position[last] = pos;
        list.pop();
        delete _position[tokenId];
        delete holderOf[tokenId];
        nft.transferFrom(address(this), msg.sender, tokenId);
        emit Delisted(msg.sender, tokenId);
    }

    function redeem(uint256 amount) external {
        _accruePoints(msg.sender);
        if (points[msg.sender] < amount) revert InsufficientPoints(points[msg.sender], amount);
        points[msg.sender] -= amount;
        emit Redeemed(msg.sender, amount);
    }
}
