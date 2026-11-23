// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice NFT locks kept in an enumerated list. Matured locks are pruned and credited as yield.
contract EnumeratedNftLocks {
    error NotHolder(uint256 tokenId);
    error StillLocked(uint256 unlockAt);

    uint256 private constant PRECISION = 1e18;
    uint256 public constant LOCK_PERIOD = 14 days;
    uint256 public constant YIELD_PER_LOCK = 5 * PRECISION;

    IERC721 public immutable nft;
    IERC20 public immutable token;

    struct Lock {
        uint256 tokenId;
        uint256 unlockAt;
    }
    mapping(address => Lock[]) private _locks;
    mapping(address => uint256) public stakedCount;
    mapping(address => uint256) public unclaimed;
    mapping(uint256 => address) public holder;
    mapping(uint256 => uint256) public unlockAt;

    event LockStarted(address indexed user, uint256 tokenId, uint256 unlockAt);
    event LockReleased(address indexed user, uint256 tokenId);
    event YieldClaimed(address indexed user, uint256 amount);

    constructor(IERC721 _nft, IERC20 _token) {
        nft = _nft;
        token = _token;
    }

    function activeLocks(address who) external view returns (uint256) {
        return _locks[who].length;
    }

    /// @dev Moves matured locks out of the list and credits one yield unit each.
    function _settleAndPrune(address who) internal {
        Lock[] storage list = _locks[who];
        uint256 i = 0;
        while (i < list.length) {
            if (block.timestamp >= list[i].unlockAt) {
                unclaimed[who] += YIELD_PER_LOCK;
                list[i] = list[list.length - 1];
                list.pop();
            } else {
                i++;
            }
        }
    }

    function stakeNFT(uint256 tokenId) external {
        _settleAndPrune(msg.sender);
        uint256 until = block.timestamp + LOCK_PERIOD;
        _locks[msg.sender].push(Lock({tokenId: tokenId, unlockAt: until}));
        stakedCount[msg.sender] += 1;
        holder[tokenId] = msg.sender;
        unlockAt[tokenId] = until;
        nft.transferFrom(msg.sender, address(this), tokenId);
        emit LockStarted(msg.sender, tokenId, until);
    }

    function withdrawNFT(uint256 tokenId) external {
        _settleAndPrune(msg.sender);
        if (holder[tokenId] != msg.sender) revert NotHolder(tokenId);
        if (block.timestamp < unlockAt[tokenId]) revert StillLocked(unlockAt[tokenId]);
        stakedCount[msg.sender] -= 1;
        delete holder[tokenId];
        delete unlockAt[tokenId];
        nft.transferFrom(address(this), msg.sender, tokenId);
        emit LockReleased(msg.sender, tokenId);
    }

    function claimYield() external {
        _settleAndPrune(msg.sender);
        uint256 amount = unclaimed[msg.sender];
        require(amount > 0, "nothing");
        unclaimed[msg.sender] = 0;
        require(token.transfer(msg.sender, amount), "push failed");
        emit YieldClaimed(msg.sender, amount);
    }
}
