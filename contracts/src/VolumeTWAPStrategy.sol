// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Volume TWAP Strategy
/// @notice Tracks a 10-step rolling volume TWAP using a circular buffer.
///         If an incoming swap's size exceeds the TWAP, spike the fee by 25 bps.
///
/// Slot layout:
///   0-9:  Circular buffer — cumulative trade volume per step (WAD)
///   10:   Current write index in the circular buffer
///   11:   Timestamp of the last trade seen
///   12:   Cached sum of all 10 buffer slots
///   13:   Total steps observed (for warmup gating)
contract Strategy is AMMStrategyBase {
    uint256 public constant BASE_FEE = 30 * BPS;
    uint256 public constant SPIKE_ADD = 25 * BPS;
    uint256 public constant WINDOW = 10;

    // Metadata slot indices (after the 10-slot buffer)
    uint256 private constant SLOT_IDX = 10;
    uint256 private constant SLOT_LAST_TS = 11;
    uint256 private constant SLOT_SUM = 12;
    uint256 private constant SLOT_STEPS = 13;

    function afterInitialize(uint256, uint256) external pure override returns (uint256, uint256) {
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 idx = readSlot(SLOT_IDX);
        uint256 lastTs = readSlot(SLOT_LAST_TS);
        uint256 sum = readSlot(SLOT_SUM);
        uint256 stepsSeen = readSlot(SLOT_STEPS);
        uint256 size = trade.amountY;

        // Advance the circular buffer for each new step since the last trade.
        // Steps with no trades get zero volume recorded.
        if (lastTs > 0 && trade.timestamp > lastTs) {
            uint256 gap = trade.timestamp - lastTs;
            if (gap > WINDOW) gap = WINDOW;

            for (uint256 i = 0; i < gap; i++) {
                idx = (idx + 1) % WINDOW;
                uint256 old = readSlot(idx);
                sum = sum > old ? sum - old : 0;
                writeSlot(idx, 0);
            }
            stepsSeen += gap;
        }

        // Compute TWAP from historical buffer *before* including the current trade.
        // This way we compare the incoming trade against prior history only.
        uint256 twap = sum / WINDOW;

        // Accumulate the current trade's volume into the current slot.
        uint256 cur = readSlot(idx);
        writeSlot(idx, cur + size);
        sum += size;

        // Spike fee if the incoming trade exceeds the historical TWAP
        // (only after the warmup window so the TWAP is meaningful).
        uint256 fee = BASE_FEE;
        if (stepsSeen >= WINDOW && twap > 0 && size > twap) {
            fee = BASE_FEE + SPIKE_ADD;
        }

        writeSlot(SLOT_IDX, idx);
        writeSlot(SLOT_LAST_TS, trade.timestamp);
        writeSlot(SLOT_SUM, sum);
        writeSlot(SLOT_STEPS, stepsSeen);

        return (fee, fee);
    }

    function getName() external pure override returns (string memory) {
        return "VolumeTWAP";
    }
}
