// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/**
 * @title ME (v3.3)
 * @notice Fixed-supply token sold along a constant-product bonding curve.
 *
 * CHANGES vs v3.2
 * ---------------
 * [M-1] MIN_TRADE_MON no longer traps small positions. The dust floor still
 *       applies to buys and to PARTIAL sells, but a holder can always sell
 *       their ENTIRE balance regardless of its value (only a position worth
 *       ~1 wei of MON, which has no value, can fail to exit).
 * [I-1] withdrawableCurveReserve() renamed curveReserveMON() (nobody can
 *       "withdraw" the reserve; the name was misleading).
 * [I-2] Documentation: retained pool fees are permanent curve liquidity.
 *
 * DESIGN NOTES
 * ------------
 * - The 80 bps pool fee is retained in `reserveMON` and re-based into
 *   `curveK` after every trade. It deepens the curve permanently; it can
 *   never be withdrawn by holders or the owner, even after all ME has been
 *   sold back. The price floor therefore only ratchets upward.
 * - The owner cannot pause, reprice, or touch user balances or the curve
 *   reserve. Owner privileges: claim 20 bps fees, rescue forced MON surplus,
 *   rescue foreign tokens (never ME). Use a multisig as owner.
 *
 * CHANGES vs ME-upgraded.sol (earlier audit)
 * ------------------------------------------
 * [H-1] Pool-fee leakage fixed via the re-based curve constant `curveK`.
 * [M-1] Ownable2Step + renounceOwnership disabled.
 * [L-1] Total fee rounds UP once; owner share rounds down; pool gets the
 *       remainder.
 * [L-2] Dedicated errors; pragma pinned; events before external payout.
 */
contract ME is
    ERC20,
    Ownable2Step,
    ReentrancyGuard,
    ERC721Holder,
    ERC1155Holder
{
    using SafeERC20 for IERC20;

    // =============================================================
    //                         TOKENOMICS
    // =============================================================

    uint256 public constant TOTAL_SUPPLY = 100_000_000_000 ether;

    /// @dev Virtual MON anchor. Mathematical only; nobody deposits it.
    uint256 public constant BASE_MON = 100_000 ether;

    /// @dev Initial curve constant. The live constant is `curveK`
    ///      and can only grow (fees deepen the curve).
    uint256 public constant INITIAL_K = BASE_MON * TOTAL_SUPPLY;

    /// @dev Fees are charged on gross trade value. Nominal total is 100 bps.
    ///      For rounding, total fee rounds up once, owner share rounds down,
    ///      and the curve receives the remainder; tiny trades may not split
    ///      the fee at an exact 80/20 ratio.
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant POOL_FEE_BPS = 80;
    uint256 public constant OWNER_FEE_BPS = 20;

    /// @notice Minimum gross trade value in native MON units (18 decimals).
    /// @dev Applies to buys and to partial sells. A sale of the seller's
    ///      ENTIRE balance is always allowed. 0.01 MON. Verify the target chain's native currency uses 18 decimals
    ///      before deployment; change this constant and retest if it does not.
    uint256 public constant MIN_TRADE_MON = 0.01 ether;

    /// @notice Live curve constant: virtualReserveMON() * remainingME().
    ///         Non-decreasing; re-based after every trade.
    uint256 public curveK = INITIAL_K;

    /// @notice Actual MON backing the curve (excludes owner fees).
    uint256 public reserveMON;

    /// @notice Owner fees held for pull-based withdrawal.
    uint256 public accruedOwnerFees;

    /// @dev True only while sellME() moves ME back into the curve.
    bool private _inSell;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event Buy(
        address indexed buyer,
        uint256 monIn,
        uint256 meOut,
        uint256 reserveAfter,
        uint256 remainingMEAfter
    );

    event Sell(
        address indexed seller,
        uint256 meIn,
        uint256 monOut,
        uint256 reserveAfter,
        uint256 remainingMEAfter
    );

    event TradeFee(
        address indexed trader,
        bool indexed isBuy,
        uint256 poolFee,
        uint256 ownerFee
    );

    event CurveRebased(uint256 newK);
    event OwnerFeesClaimed(address indexed owner, address indexed to, uint256 amount);
    event SurplusRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event ERC721Rescued(address indexed token, address indexed to, uint256 tokenId);
    event ERC1155Rescued(address indexed token, address indexed to, uint256 id, uint256 amount);

    // =============================================================
    //                            ERRORS
    // =============================================================

    error ZeroAmount();
    error NoMEAvailable();
    error AmountTooSmall();
    error InsufficientME();
    error InsufficientReserve();
    error InsufficientMON();
    error DirectMONNotAllowed();
    error DirectMEToContractNotAllowed();
    error MONTransferFailed();
    error InvalidState();
    error SlippageExceeded();
    error DeadlineExpired();
    error NothingToRescue();
    error NoFeesToClaim();
    error ZeroAddress();
    error CannotRescueME();
    error InvalidTokenContract();
    error RenounceDisabled();

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    constructor() ERC20("ME", "ME") Ownable(msg.sender) {
        // Entire fixed supply starts inside the curve. No MON required.
        _mint(address(this), TOTAL_SUPPLY);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    // =============================================================
    //                      OWNERSHIP HARDENING
    // =============================================================

    /// @dev Renouncing would permanently lock accrued fees and rescue
    ///      functions, so it is disabled. Use two-step transfer instead.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // =============================================================
    //                       CURVE STATE VIEWS
    // =============================================================

    function remainingME() public view returns (uint256) {
        return balanceOf(address(this));
    }

    function circulatingME() public view returns (uint256) {
        return TOTAL_SUPPLY - remainingME();
    }

    /// @notice Mathematical MON reserve (includes the virtual anchor).
    function virtualReserveMON() public view returns (uint256) {
        return BASE_MON + reserveMON;
    }

    function actualMON() public view returns (uint256) {
        return address(this).balance;
    }

    /// @notice MON above curve reserve + owner-fee liability.
    function surplusMON() public view returns (uint256) {
        uint256 accounted = reserveMON + accruedOwnerFees;
        uint256 balance = address(this).balance;
        return balance > accounted ? balance - accounted : 0;
    }

    function reserveSolvent() public view returns (bool) {
        return address(this).balance >= reserveMON + accruedOwnerFees;
    }

    /// @notice Native MON backing the curve, excluding owner-fee liability.
    function curveReserveMON() external view returns (uint256) {
        return reserveMON;
    }

    /// @notice Total accounted native MON liabilities.
    function accountedMON() external view returns (uint256) {
        return reserveMON + accruedOwnerFees;
    }

    /// @notice Single-call accounting snapshot for dashboards and monitoring.
    function accountingStatus()
        external
        view
        returns (
            uint256 actualBalance,
            uint256 curveReserve,
            uint256 ownerFeeLiability,
            uint256 surplus,
            uint256 liveK,
            uint256 tokensRemaining,
            bool solvent
        )
    {
        actualBalance = address(this).balance;
        curveReserve = reserveMON;
        ownerFeeLiability = accruedOwnerFees;
        surplus = actualBalance > curveReserve + ownerFeeLiability
            ? actualBalance - curveReserve - ownerFeeLiability
            : 0;
        liveK = curveK;
        tokensRemaining = remainingME();
        solvent = actualBalance >= curveReserve + ownerFeeLiability;
    }

    /// @notice Marginal price: MON per ME scaled by 1e18.
    function currentPrice() public view returns (uint256) {
        uint256 meLeft = remainingME();
        if (meLeft == 0) revert NoMEAvailable();
        return Math.mulDiv(virtualReserveMON(), 1 ether, meLeft);
    }

    // =============================================================
    //                          CURVE MATH
    // =============================================================

    /// @dev ME that must remain once the virtual reserve is `reserve`.
    ///      Ceil rounding so the curve never over-pays.
    function _remainingForReserve(uint256 reserve) internal view returns (uint256) {
        return Math.mulDiv(curveK, 1, reserve, Math.Rounding.Ceil);
    }

    // =============================================================
    //                     SHARED QUOTE LOGIC
    // =============================================================
    // quote*() views and buyME()/sellME() use the same helpers so
    // preview and execution can never drift apart.

    /// @dev Total fee rounds UP once, so it can exceed the nominal 1% by
    ///      less than one wei. For tiny gross values the effective rate can
    ///      be much higher; callers should enforce a meaningful minimum trade.
    ///      Owner share rounds DOWN and the remainder goes to the curve.
    function _fees(uint256 gross)
        internal
        pure
        returns (uint256 poolFee, uint256 ownerFee)
    {
        uint256 totalFee = Math.mulDiv(
            gross,
            POOL_FEE_BPS + OWNER_FEE_BPS,
            FEE_DENOMINATOR,
            Math.Rounding.Ceil
        );

        ownerFee = Math.mulDiv(
            gross,
            OWNER_FEE_BPS,
            FEE_DENOMINATOR,
            Math.Rounding.Floor
        );

        poolFee = totalFee - ownerFee;
    }

    /// @notice Returns the exact fee split used by both buy and sell execution.
    function calculateFees(uint256 gross)
        external
        pure
        returns (uint256 poolFee, uint256 ownerFee, uint256 totalFee)
    {
        (poolFee, ownerFee) = _fees(gross);
        totalFee = poolFee + ownerFee;
    }

    function _splitBuy(uint256 monIn)
        internal
        pure
        returns (uint256 poolFee, uint256 ownerFee, uint256 tradeAmount)
    {
        if (monIn == 0) revert ZeroAmount();
        if (monIn < MIN_TRADE_MON) revert AmountTooSmall();
        (poolFee, ownerFee) = _fees(monIn);
        if (poolFee + ownerFee >= monIn) revert AmountTooSmall();
        tradeAmount = monIn - poolFee - ownerFee;
    }

    function _computeBuy(uint256 tradeAmount)
        internal
        view
        returns (uint256 meOut, uint256 newRemaining)
    {
        uint256 meLeft = remainingME();
        if (meLeft == 0) revert NoMEAvailable();

        newRemaining = _remainingForReserve(virtualReserveMON() + tradeAmount);
        if (newRemaining >= meLeft) revert AmountTooSmall();

        meOut = meLeft - newRemaining;
    }

    /// @return grossOut MON released by the curve before fees.
    function _computeSell(address seller, uint256 meIn)
        internal
        view
        returns (uint256 grossOut)
    {
        if (seller == address(0)) revert InvalidState();
        if (meIn == 0) revert ZeroAmount();
        if (balanceOf(seller) < meIn) revert InsufficientME();

        uint256 oldVirtual = virtualReserveMON();
        uint256 newVirtual = _remainingForReserve(remainingME() + meIn);

        if (oldVirtual <= newVirtual) revert AmountTooSmall();
        grossOut = oldVirtual - newVirtual;

        if (grossOut > reserveMON) revert InsufficientReserve();
        if (grossOut > address(this).balance) revert InsufficientMON();

        // Dust floor applies to partial sells only. A holder may always exit
        // their entire balance, so no position can be trapped by the floor.
        if (grossOut < MIN_TRADE_MON && meIn != balanceOf(seller)) {
            revert AmountTooSmall();
        }
    }

    function _netSell(uint256 grossOut)
        internal
        pure
        returns (uint256 poolFee, uint256 ownerFee, uint256 netOut)
    {
        (poolFee, ownerFee) = _fees(grossOut);
        if (poolFee + ownerFee >= grossOut) revert AmountTooSmall();
        netOut = grossOut - poolFee - ownerFee;
    }

    /// @dev Re-base K to the current (reserve, remaining) point so that
    ///      retained fees deepen the curve and leave no extractable
    ///      surplus. K can only grow; this is asserted.
    function _rebaseCurve() internal {
        uint256 newK = virtualReserveMON() * remainingME();
        if (newK < curveK) revert InvalidState();
        curveK = newK;
        emit CurveRebased(newK);
    }

    // =============================================================
    //                             BUY
    // =============================================================

    function quoteBuy(uint256 monIn) external view returns (uint256 meOut) {
        (, , uint256 tradeAmount) = _splitBuy(monIn);
        (meOut, ) = _computeBuy(tradeAmount);
    }

    /// @notice Returns the ME output and exact fee split for a buy quote.
    function quoteBuyDetailed(uint256 monIn)
        external
        view
        returns (uint256 meOut, uint256 poolFee, uint256 ownerFee)
    {
        uint256 tradeAmount;
        (poolFee, ownerFee, tradeAmount) = _splitBuy(monIn);
        (meOut, ) = _computeBuy(tradeAmount);
    }

    /// @param minMeOut Minimum ME accepted (slippage protection).
    /// @param deadline Unix timestamp after which the tx reverts.
    function buyME(uint256 minMeOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 meOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();

        uint256 monIn = msg.value;
        (uint256 poolFee, uint256 ownerFee, uint256 tradeAmount) = _splitBuy(monIn);

        (meOut, ) = _computeBuy(tradeAmount);
        if (meOut < minMeOut) revert SlippageExceeded();

        // Pool fee stays in the curve reserve; owner fee is a liability.
        reserveMON += monIn - ownerFee;
        accruedOwnerFees += ownerFee;

        _transfer(address(this), msg.sender, meOut);

        _rebaseCurve();
        _checkCurveState();

        emit TradeFee(msg.sender, true, poolFee, ownerFee);
        emit Buy(msg.sender, monIn, meOut, reserveMON, remainingME());
    }

    // =============================================================
    //                             SELL
    // =============================================================

    function quoteSell(uint256 meIn) external view returns (uint256 monOut) {
        (, , monOut) = _netSell(_computeSell(msg.sender, meIn));
    }

    function quoteSellFor(address seller, uint256 meIn)
        external
        view
        returns (uint256 monOut)
    {
        (, , monOut) = _netSell(_computeSell(seller, meIn));
    }

    /// @notice Returns net MON output and exact fee split for a sell quote.
    function quoteSellDetailed(address seller, uint256 meIn)
        external
        view
        returns (uint256 monOut, uint256 poolFee, uint256 ownerFee)
    {
        uint256 grossOut = _computeSell(seller, meIn);
        (poolFee, ownerFee, monOut) = _netSell(grossOut);
    }

    function _transferForSell(address seller, uint256 meIn) internal {
        _inSell = true;
        _transfer(seller, address(this), meIn);
        _inSell = false;
    }

    /// @param minMonOut Minimum MON accepted (slippage protection).
    /// @param deadline  Unix timestamp after which the tx reverts.
    function sellME(uint256 meIn, uint256 minMonOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 monOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();

        uint256 grossOut = _computeSell(msg.sender, meIn);
        uint256 poolFee;
        uint256 ownerFee;
        (poolFee, ownerFee, monOut) = _netSell(grossOut);

        if (monOut < minMonOut) revert SlippageExceeded();

        // EFFECTS
        _transferForSell(msg.sender, meIn);

        reserveMON -= grossOut - poolFee;
        accruedOwnerFees += ownerFee;

        _rebaseCurve();
        _checkCurveState();

        emit TradeFee(msg.sender, false, poolFee, ownerFee);
        emit Sell(msg.sender, meIn, monOut, reserveMON, remainingME());

        // INTERACTION
        (bool success, ) = payable(msg.sender).call{value: monOut}("");
        if (!success) revert MONTransferFailed();
    }

    // =============================================================
    //                      CURVE STATE CHECK
    // =============================================================

    /// @dev Sanity checks (do not change economics):
    ///      - remaining ME never exceeds total supply
    ///      - actual MON covers reserve + owner-fee liability
    ///      - curveK never falls below the initial constant
    ///      - curve point is consistent: virtualReserve * remaining >= K
    function _checkCurveState() internal view {
        uint256 meLeft = remainingME();
        uint256 liabilities = reserveMON + accruedOwnerFees;
        uint256 curveProduct = virtualReserveMON() * meLeft;

        if (meLeft == 0 || meLeft > TOTAL_SUPPLY) revert InvalidState();
        if (address(this).balance < liabilities) revert InvalidState();
        if (curveK < INITIAL_K) revert InvalidState();
        if (curveProduct < curveK) revert InvalidState();
    }

    // =============================================================
    //                       ERC20 TRANSFER GUARD
    // =============================================================

    /// @dev Blocks ME being sent into the curve outside of the
    ///      constructor mint and an authorized sellME().
    function _update(address from, address to, uint256 value) internal override {
        if (to == address(this)) {
            bool constructorMint =
                from == address(0) &&
                value == TOTAL_SUPPLY &&
                totalSupply() == 0;

            bool authorizedSell = from != address(0) && _inSell;

            if (!constructorMint && !authorizedSell) {
                revert DirectMEToContractNotAllowed();
            }
        }

        super._update(from, to, value);
    }

    // =============================================================
    //                    DIRECT MON PROTECTION
    // =============================================================

    receive() external payable {
        revert DirectMONNotAllowed();
    }

    fallback() external payable {
        revert DirectMONNotAllowed();
    }

    // =============================================================
    //                     OWNER MAINTENANCE
    // =============================================================
    // The owner cannot pause, reprice, or touch user balances or the
    // curve reserve. Privileges: withdraw accrued fees, rescue forced
    // MON surplus, rescue foreign tokens (never ME).

    /// @notice Withdraw accrued owner fees (pull-based; never blocks trades).
    function claimOwnerFees(address payable to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        uint256 amount = accruedOwnerFees;
        if (amount == 0) revert NoFeesToClaim();
        address feeOwner = owner();

        accruedOwnerFees = 0;

        (bool success, ) = to.call{value: amount}("");
        if (!success) revert MONTransferFailed();

        emit OwnerFeesClaimed(feeOwner, to, amount);
    }

    /// @notice Rescue MON above curve reserve and accrued owner fees.
    function rescueSurplusMON(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        uint256 amount = surplusMON();
        if (amount == 0) revert NothingToRescue();

        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert MONTransferFailed();

        emit SurplusRescued(to, amount);
    }

    function rescueERC20(address token, address to) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (token == address(this)) revert CannotRescueME();
        if (token.code.length == 0) revert InvalidTokenContract();

        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue();

        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function rescueERC721(address token, uint256 tokenId, address to)
        external
        onlyOwner
        nonReentrant
    {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (token == address(this)) revert CannotRescueME();
        if (token.code.length == 0) revert InvalidTokenContract();

        IERC721(token).safeTransferFrom(address(this), to, tokenId);
        emit ERC721Rescued(token, to, tokenId);
    }

    function rescueERC1155(address token, uint256 id, address to)
        external
        onlyOwner
        nonReentrant
    {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (token == address(this)) revert CannotRescueME();
        if (token.code.length == 0) revert InvalidTokenContract();

        uint256 amount = IERC1155(token).balanceOf(address(this), id);
        if (amount == 0) revert NothingToRescue();

        IERC1155(token).safeTransferFrom(address(this), to, id, amount, "");
        emit ERC1155Rescued(token, to, id, amount);
    }
}
