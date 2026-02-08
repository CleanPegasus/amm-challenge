// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Bubble Sort Fee V4 — V10 params + adaptive spike scale
/// @notice Uses ProportionalSpikeV10 as core (scale=40, max=120) with
///         bubble sort to adaptively tune the spike scale.
contract Strategy is AMMStrategyBase {
    uint256 public constant NUM_SCALES = 5;

    uint256 private constant SLOT_SCALES = 0;
    uint256 private constant SLOT_SCORES = 5;
    uint256 private constant SLOT_VOL_EMA = 10;
    uint256 private constant SLOT_LAST_STEP = 11;
    uint256 private constant SLOT_SPIKE_FEE = 12;
    uint256 private constant SLOT_TRADE_COUNT = 13;
    uint256 private constant SLOT_CONSEC_ARB = 14;

    uint256 public constant BASE_FEE = 25 * BPS;
    uint256 public constant MAX_SPIKE = 120 * BPS;
    uint256 public constant ALPHA = WAD / 10;
    uint256 public constant DECAY_SPEED = WAD / 10;
    uint256 public constant THRESHOLD_NUM = 3;
    uint256 public constant THRESHOLD_DENOM = 2;

    uint256 public constant SORT_INTERVAL = 20;
    uint256 public constant SCORE_DECAY = WAD * 85 / 100;

    function afterInitialize(uint256, uint256) external override returns (uint256, uint256) {
        writeSlot(SLOT_SCALES + 0, 40 * BPS);   // V10 proven value
        writeSlot(SLOT_SCALES + 1, 30 * BPS);
        writeSlot(SLOT_SCALES + 2, 35 * BPS);
        writeSlot(SLOT_SCALES + 3, 50 * BPS);
        writeSlot(SLOT_SCALES + 4, 60 * BPS);
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 size = trade.amountY;
        uint256 volEma = readSlot(SLOT_VOL_EMA);
        uint256 lastStep = readSlot(SLOT_LAST_STEP);
        uint256 spikeFee = readSlot(SLOT_SPIKE_FEE);
        uint256 tradeCount = readSlot(SLOT_TRADE_COUNT) + 1;
        uint256 consecArb = readSlot(SLOT_CONSEC_ARB);

        if (volEma == 0) {
            volEma = size;
        } else {
            volEma = (ALPHA * size + (WAD - ALPHA) * volEma) / WAD;
        }

        if (spikeFee > 0 && trade.timestamp > lastStep) {
            uint256 elapsed = trade.timestamp - lastStep;
            spikeFee = spikeFee * WAD / (WAD + elapsed * DECAY_SPEED);
        }

        uint256 activeScale = readSlot(SLOT_SCALES + 0);
        uint256 threshold = volEma * THRESHOLD_NUM / THRESHOLD_DENOM;

        if (size > threshold && threshold > 0) {
            consecArb = consecArb + 1;
            uint256 excess = size - threshold;
            uint256 add = activeScale * excess / threshold;
            if (add > MAX_SPIKE) add = MAX_SPIKE;
            spikeFee = spikeFee + add;
            if (spikeFee > MAX_SPIKE) spikeFee = MAX_SPIKE;

            uint256 scaleIdx = consecArb % NUM_SCALES;
            uint256 score = readSlot(SLOT_SCORES + scaleIdx);
            writeSlot(SLOT_SCORES + scaleIdx, score + WAD);
        } else {
            consecArb = 0;
            uint256 score = readSlot(SLOT_SCORES + 0);
            if (score > WAD / 4) {
                writeSlot(SLOT_SCORES + 0, score - WAD / 4);
            } else {
                writeSlot(SLOT_SCORES + 0, 0);
            }
        }

        if (tradeCount % SORT_INTERVAL == 0) {
            for (uint256 i = 0; i < NUM_SCALES - 1; i++) {
                uint256 sI = readSlot(SLOT_SCORES + i);
                uint256 sJ = readSlot(SLOT_SCORES + i + 1);
                if (sI > sJ) {
                    uint256 scaleI = readSlot(SLOT_SCALES + i);
                    uint256 scaleJ = readSlot(SLOT_SCALES + i + 1);
                    writeSlot(SLOT_SCALES + i, scaleJ);
                    writeSlot(SLOT_SCALES + i + 1, scaleI);
                    writeSlot(SLOT_SCORES + i, sJ);
                    writeSlot(SLOT_SCORES + i + 1, sI);
                }
                uint256 s = readSlot(SLOT_SCORES + i);
                writeSlot(SLOT_SCORES + i, s * SCORE_DECAY / WAD);
            }
            uint256 lastS = readSlot(SLOT_SCORES + NUM_SCALES - 1);
            writeSlot(SLOT_SCORES + NUM_SCALES - 1, lastS * SCORE_DECAY / WAD);
        }

        uint256 fee = clampFee(BASE_FEE + spikeFee);

        writeSlot(SLOT_VOL_EMA, volEma);
        writeSlot(SLOT_LAST_STEP, trade.timestamp);
        writeSlot(SLOT_SPIKE_FEE, spikeFee);
        writeSlot(SLOT_TRADE_COUNT, tradeCount);
        writeSlot(SLOT_CONSEC_ARB, consecArb);

        return (fee, fee);
    }

    function getName() external pure override returns (string memory) {
        return "BubbleSortFeeV4";
    }
}
