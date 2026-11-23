// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Per-pair LP accounting. Each pair has two fee indices (one per side)
/// and a keyed position per user. Pairs are addressed by a bytes32 identifier.
contract PairLpIndexLedger {
    uint256 private constant Q = 1e18;

    struct Pair {
        IERC20 tokenA;
        IERC20 tokenB;
        uint256 totalShares;
        uint256 indexA;
        uint256 indexB;
    }

    struct UserPair {
        uint256 shares;
        uint256 indexAPaid;
        uint256 indexBPaid;
        uint256 owedA;
        uint256 owedB;
    }

    address public immutable governor;
    mapping(bytes32 => Pair) public pairs;
    mapping(bytes32 => mapping(address => UserPair)) public userPairs;

    event PairCreated(bytes32 indexed pairId, address tokenA, address tokenB);
    event PairSupplied(bytes32 indexed pairId, address indexed user, uint256 shares);
    event PairRedeemed(bytes32 indexed pairId, address indexed user, uint256 shares);
    event PairFeesCredited(bytes32 indexed pairId, uint256 feeA, uint256 feeB);

    constructor() {
        governor = msg.sender;
    }

    function createPair(bytes32 pairId, IERC20 a, IERC20 b) external {
        require(msg.sender == governor, "not governor");
        require(address(pairs[pairId].tokenA) == address(0), "exists");
        pairs[pairId] = Pair({tokenA: a, tokenB: b, totalShares: 0, indexA: 0, indexB: 0});
        emit PairCreated(pairId, address(a), address(b));
    }

    function creditPairFees(bytes32 pairId, uint256 feeA, uint256 feeB) external {
        require(msg.sender == governor, "not governor");
        Pair storage p = pairs[pairId];
        require(p.totalShares > 0, "no shares");
        p.indexA += feeA * Q / p.totalShares;
        p.indexB += feeB * Q / p.totalShares;
        emit PairFeesCredited(pairId, feeA, feeB);
    }

    function supplyPair(bytes32 pairId, uint256 shares) external {
        require(shares > 0, "zero shares");
        require(address(pairs[pairId].tokenA) != address(0), "no pair");
        _catchUpPair(pairId, msg.sender);
        UserPair storage u = userPairs[pairId][msg.sender];
        Pair storage p = pairs[pairId];
        u.shares += shares;
        p.totalShares += shares;
        emit PairSupplied(pairId, msg.sender, shares);
    }

    function redeemPair(bytes32 pairId, uint256 shares) external {
        UserPair storage u = userPairs[pairId][msg.sender];
        require(shares <= u.shares, "insufficient shares");
        _catchUpPair(pairId, msg.sender);
        u.shares -= shares;
        pairs[pairId].totalShares -= shares;
        if (u.shares == 0 && u.owedA == 0 && u.owedB == 0) {
            delete userPairs[pairId][msg.sender];
        }
        emit PairRedeemed(pairId, msg.sender, shares);
    }

    function claimPairFees(bytes32 pairId) external {
        _catchUpPair(pairId, msg.sender);
        UserPair storage u = userPairs[pairId][msg.sender];
        Pair storage p = pairs[pairId];
        uint256 a = u.owedA;
        uint256 b = u.owedB;
        u.owedA = 0;
        u.owedB = 0;
        if (a > 0) require(p.tokenA.transfer(msg.sender, a), "transfer A failed");
        if (b > 0) require(p.tokenB.transfer(msg.sender, b), "transfer B failed");
    }

    /// @dev Books fees for both sides since the user's last indices, using the
    /// share count the user held up to this call.
    function _catchUpPair(bytes32 pairId, address who) internal {
        Pair storage p = pairs[pairId];
        UserPair storage u = userPairs[pairId][who];
        if (u.shares > 0) {
            u.owedA += u.shares * (p.indexA - u.indexAPaid) / Q;
            u.owedB += u.shares * (p.indexB - u.indexBPaid) / Q;
        }
        u.indexAPaid = p.indexA;
        u.indexBPaid = p.indexB;
    }
}
