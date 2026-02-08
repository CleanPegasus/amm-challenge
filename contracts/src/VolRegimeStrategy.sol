// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Volatility-Regime Strategy
/// @notice Continuously estimates volatility via EMA of trade sizes and maps
///         it to a fee using a smooth saturation curve. No spikes — just steady
///         adaptation to market conditions.
///
///         fee = MIN_FEE + FEE_RANGE * volEma / (volEma + MIDPOINT)
///
///         This gives:
///           - Calm markets (small retail, volEma ~10Y): ~26 bps (undercut normalizer)
///           - Normal markets (volEma ~20Y):            ~30 bps (match normalizer)
///           - Volatile markets (volEma ~80Y):          ~42 bps (protect from arbs)
///           - Very volatile (volEma ~200Y):            ~50 bps (strong protection)
///
/// Slot layout:
///   0: volEma      - EMA of trade sizes (WAD)
///   1: tradeCount  - number of trades seen (for warmup)
contract Strategy is AMMStrategyBase {
    /// @notice Minimum fee (floor) in calm markets: 22 bps
    uint256 public constant MIN_TOTAL_FEE = 22 * BPS;

    /// @notice Maximum fee (ceiling) in volatile markets: 60 bps
    uint256 public constant MAX_TOTAL_FEE = 60 * BPS;

    /// @notice Fee range: MAX - MIN = 38 bps
    uint256 public constant FEE_RANGE = MAX_TOTAL_FEE - MIN_TOTAL_FEE;

    /// @notice Midpoint of the saturation curve (75 Y tokens in WAD)
    /// At volEma = MIDPOINT, fee = MIN_FEE + RANGE/2 = 41 bps
    /// Calibrated so volEma ≈ 20Y (typical retail) gives ~30 bps
    uint256 public constant MIDPOINT = 75 * WAD;

    /// @notice EMA smoothing factor: 20% weight to new observation (faster than spike-decay)
    uint256 public constant ALPHA = WAD / 5;

    /// @notice Number of trades to warm up before using adaptive fee
    uint256 public constant WARMUP = 3;

    /// @notice Default fee during warmup
    uint256 public constant DEFAULT_FEE = 30 * BPS;

    // Slot indices
    uint256 private constant SLOT_VOL_EMA = 0;
    uint256 private constant SLOT_TRADE_COUNT = 1;

    function afterInitialize(uint256, uint256) external pure override returns (uint256, uint256) {
        return (DEFAULT_FEE, DEFAULT_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 size = trade.amountY;
        uint256 volEma = readSlot(SLOT_VOL_EMA);
        uint256 count = readSlot(SLOT_TRADE_COUNT);

        count += 1;

        // Update EMA
        if (volEma == 0) {
            volEma = size;
        } else {
            volEma = (ALPHA * size + (WAD - ALPHA) * volEma) / WAD;
        }

        // Compute fee via saturation curve
        uint256 fee;
        if (count < WARMUP) {
            fee = DEFAULT_FEE;
        } else {
            // fee = MIN_FEE + RANGE * volEma / (volEma + MIDPOINT)
            fee = MIN_TOTAL_FEE + wmul(FEE_RANGE, wdiv(volEma, volEma + MIDPOINT));
        }

        fee = clampFee(fee);

        writeSlot(SLOT_VOL_EMA, volEma);
        writeSlot(SLOT_TRADE_COUNT, count);

        return (fee, fee);
    }

    function getName() external pure override returns (string memory) {
        return "VolRegime";
    }
}
