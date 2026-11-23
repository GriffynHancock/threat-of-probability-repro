// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Per-token records. Each NFT carries its own accrual record; owners aggregate a count and an owed balance.
contract TokenRecordStaking {
    uint256 private constant PRECISION = 1e18;

    IERC721 public immutable nft;
    IERC20 public immutable rewardToken;
    uint256 public immutable ratePerSecond;

    struct Record {
        address staker;
        uint256 lastSettled;
        uint256 accrued;
    }
    mapping(uint256 => Record) public records;

    mapping(address => uint256) public stakedCount;
    mapping(address => uint256) public owed;

    event TokenStaked(address indexed user, uint256 tokenId);
    event TokenUnstaked(address indexed user, uint256 tokenId);
    event OwedClaimed(address indexed user, uint256 amount);

    constructor(IERC721 _nft, IERC20 _reward, uint256 _rate) {
        nft = _nft;
        rewardToken = _reward;
        ratePerSecond = _rate;
    }

    /// @dev Settles the token record into its staker's owed balance. No-op for an unstaked token.
    function _settleTokenRecord(uint256 tokenId) internal {
        Record storage r = records[tokenId];
        if (r.staker == address(0)) return;
        uint256 dt = block.timestamp - r.lastSettled;
        uint256 gain = (dt * ratePerSecond) / PRECISION;
        r.accrued += gain;
        owed[r.staker] += gain;
        r.lastSettled = block.timestamp;
    }

    function stakeToken(uint256 tokenId) external {
        _settleTokenRecord(tokenId);
        records[tokenId] = Record({staker: msg.sender, lastSettled: block.timestamp, accrued: 0});
        stakedCount[msg.sender] += 1;
        nft.transferFrom(msg.sender, address(this), tokenId);
        emit TokenStaked(msg.sender, tokenId);
    }

    function unstakeToken(uint256 tokenId) external {
        require(records[tokenId].staker == msg.sender, "not staker");
        _settleTokenRecord(tokenId);
        delete records[tokenId];
        stakedCount[msg.sender] -= 1;
        nft.transferFrom(address(this), msg.sender, tokenId);
        emit TokenUnstaked(msg.sender, tokenId);
    }

    function claimOwed() external {
        uint256 amount = owed[msg.sender];
        require(amount > 0, "nothing owed");
        owed[msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, amount), "push failed");
        emit OwedClaimed(msg.sender, amount);
    }
}
