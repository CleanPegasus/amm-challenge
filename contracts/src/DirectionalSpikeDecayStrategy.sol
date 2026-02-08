// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Directional Spike-and-Decay Strategy
/// @notice Tracks trade direction and spikes fees asymmetrically.
///         When a large trade is detected (likely arb), spikes the fee
///         on the SAME side (momentum protection) while keeping the
///         opposite side competitive to attract retail.
///
/// Slot layout:
///   0: volEma      - EMA of trade sizes (WAD)
///   1: lastStep    - timestamp of last afterSwap call
///   2: bidSpikeFee - current spike component for bid side
///   3: askSpikeFee - current spike component for ask side
contract Strategy is AMMStrategyBase {
    uint256 public constant BASE_FEE = 30 * BPS;
    uint256 public constant SPIKE_ADD = 25 * BPS;
    uint256 public constant MAX_SPIKE = 50 * BPS;
    uint256 public constant ALPHA = WAD / 10;
    uint256 public constant DECAY_SPEED = WAD / 8;
    uint256 public constant ARB_MULT = 2;

    uint256 private constant SLOT_VOL_EMA = 0;
    uint256 private constant SLOT_LAST_STEP = 1;
    uint256 private constant SLOT_BID_SPIKE = 2;
    uint256 private constant SLOT_ASK_SPIKE = 3;

    function afterInitialize(uint256, uint256) external pure override returns (uint256, uint256) {
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 size = trade.amountY;
        uint256 volEma = readSlot(SLOT_VOL_EMA);
        uint256 lastStep = readSlot(SLOT_LAST_STEP);
        uint256 bidSpike = readSlot(SLOT_BID_SPIKE);
        uint256 askSpike = readSlot(SLOT_ASK_SPIKE);

        // Bootstrap EMA
        if (volEma == 0) {
            volEma = size;
        } else {
            volEma = (ALPHA * size + (WAD - ALPHA) * volEma) / WAD;
        }

        // Decay both spikes
        if (trade.timestamp > lastStep) {
            uint256 elapsed = trade.timestamp - lastStep;
            uint256 denom = WAD + elapsed * DECAY_SPEED;
            if (bidSpike > 0) bidSpike = bidSpike * WAD / denom;
            if (askSpike > 0) askSpike = askSpike * WAD / denom;
        }

        // Detect large trade → spike the SAME side (momentum protection)
        if (size > ARB_MULT * volEma) {
            if (trade.isBuy) {
                // AMM bought X (trader sold X) → spike bid side
                bidSpike = bidSpike + SPIKE_ADD;
                if (bidSpike > MAX_SPIKE) bidSpike = MAX_SPIKE;
            } else {
                // AMM sold X (trader bought X) → spike ask side
                askSpike = askSpike + SPIKE_ADD;
                if (askSpike > MAX_SPIKE) askSpike = MAX_SPIKE;
            }
        }

        uint256 bidFee = clampFee(BASE_FEE + bidSpike);
        uint256 askFee = clampFee(BASE_FEE + askSpike);

        writeSlot(SLOT_VOL_EMA, volEma);
        writeSlot(SLOT_LAST_STEP, trade.timestamp);
        writeSlot(SLOT_BID_SPIKE, bidSpike);
        writeSlot(SLOT_ASK_SPIKE, askSpike);

        return (bidFee, askFee);
    }

    function getName() external pure override returns (string memory) {
        return "DirectionalSpikeDecay";
    }
}
