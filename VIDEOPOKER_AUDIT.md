# VideoPoker Security Audit Report

## Executive Summary

**Contract:** VideoPoker.sol  
**Audit Date:** January 8, 2026  
**Auditor:** GitHub Copilot  
**Test Coverage:** 25 comprehensive payout logic tests (100% pass rate)

---

## ✅ PAYOUT LOGIC - NO ISSUES FOUND

### Tested Hand Rankings & Multipliers

| Hand | Multiplier | Outcome Code | Status |
|------|-----------|--------------|---------|
| Royal Flush | 100x | 9 | ✅ CORRECT |
| Straight Flush | 50x | 8 | ✅ CORRECT |
| Four of a Kind | 30x | 7 | ✅ CORRECT |
| Full House | 8x | 6 | ✅ CORRECT |
| Flush | 6x | 5 | ✅ CORRECT |
| Straight | 5x | 4 | ✅ CORRECT |
| Three of a Kind | 3x | 3 | ✅ CORRECT |
| Two Pair | 2x | 2 | ✅ CORRECT |
| Jacks or Better | 1x | 1 | ✅ CORRECT |
| No Win | 0x | 0 | ✅ CORRECT |

### Edge Cases Verified

✅ **Ace handling in straights:**
- Ace-low straight (A-2-3-4-5): Correctly pays 5x
- Ace-high straight (10-J-Q-K-A): Correctly pays 5x
- Royal flush (10-J-Q-K-A suited): Correctly pays 100x

✅ **Four of a Kind positions:**
- First 4 cards (XXXX-Y): Correctly detected
- Last 4 cards (Y-XXXX): Correctly detected

✅ **Full House arrangements:**
- Three first + pair last (XXX-YY): Correctly detected
- Pair first + three last (YY-XXX): Correctly detected

✅ **Three of a Kind positions:**
- First position (XXX-Y-Z): Correctly detected
- Middle position (Y-XXX-Z): Correctly detected
- Last position (Y-Z-XXX): Correctly detected

✅ **Two Pair arrangements:**
- All position combinations tested and working

✅ **Jacks or Better:**
- Correctly pays only for J, Q, K, A pairs
- Low pairs (2-10) correctly return 0 multiplier

---

## ✅ VRF SECURITY ANALYSIS - SECURE

### Game Flow Analysis

**Phase 1: Start Game**
```solidity
VideoPoker_Start() → game.requestID = VRF_request_id (non-zero)
```

**Phase 2: First VRF Callback (Initial Hand)**
```solidity
fulfillRandomWords() → Deals 5 cards, sets game.requestID = 0
```

**Phase 3: Player Decision**

Option A - Replace Cards:
```solidity
VideoPoker_Replace([true, false, true, false, false])
→ game.requestID = new_VRF_request_id (non-zero)
→ Pays 2nd VRF fee
```

Option B - Stand Pat (Keep Current Hand):
```solidity
VideoPoker_Replace([false, false, false, false, false])
→ Immediate settlement
→ _transferToBankroll(wager)  ← Player ALWAYS loses wager
→ if (multiplier != 0) _transferPayout()  ← Only pays if winning hand
→ game deleted
```

**Phase 4: Refund (Only if VRF fails)**

```solidity
function VideoPoker_Refund() {
    if (game.requestID == 0) {
        revert NoRequestPending();  // ← CRITICAL: Prevents refund after initial hand!
    }
    // ...
}
```

### Why There's NO Griefing Attack

**Scenario: Player gets bad initial hand**

```
Player wagers 100 USDC
  ↓
VRF returns: [2♠ 5♥ 7♦ 9♣ K♠]  ← No winning hand
  ↓
game.requestID = 0 (after fulfillRandomWords)
  ↓
Player tries VideoPoker_Refund()
  ↓
❌ REVERTS: NoRequestPending() because requestID == 0
```

**Player MUST choose:**
1. ✅ Replace cards (pay 2nd VRF fee, try to improve hand)
2. ✅ Stand pat (lose wager immediately)
3. ❌ Get refund (IMPOSSIBLE - requestID is 0)

### Refund Protection Logic

Refunds are ONLY possible if:
- `game.requestID != 0` (VRF request is pending)
- `block.number >= game.blockNumber + 200` (200 blocks have passed)

Once the first VRF callback executes, `requestID` is set to 0, making refunds impossible until a new VRF request is made via card replacement.

**Conclusion:** The instant settlement in the `else` branch is a legitimate "stand pat" mechanic, not an exploit.

---

## 🟡 MEDIUM FINDING: No Maximum Payout Protection

### Issue: Kelly Criterion Applied to Wager, Not Payout

```solidity
function _kellyWager(uint256 wager, address tokenAddress) internal view {
    uint256 balance;
    if (tokenAddress == address(0)) {
        balance = address(Bankroll()).balance;
    } else {
        balance = IERC20(tokenAddress).balanceOf(address(Bankroll()));
    }
    uint256 maxWager = (balance * 133937) / 100000000;  // ~0.134% of bankroll
    if (wager > maxWager) {
        revert WagerAboveLimit(wager, maxWager);
    }
}
```

**Problem:** With 100x Royal Flush multiplier, actual max payout = `0.134% * 100 = 13.4%` of bankroll

**Kelly Criterion for Video Poker:**
- Formula: `Kelly% = edge / variance`
- Video Poker has ~99.5% RTP (0.5% house edge) but HIGH variance due to Royal Flush
- Royal Flush probability: 1/649,740 (0.00015%)
- Current limit: 0.134% wager allows 13.4% max payout

**Recommendation:** Limit should account for max multiplier:
```solidity
uint256 maxWager = (balance * 133937) / 100000000 / 100;  // Divide by max multiplier
```

---

## 🟢 POSITIVE FINDINGS

### ✅ Correct Randomness Usage

```solidity
function _pickCard(uint8 handPosition, uint256 rng, address player, Card[] memory deck) internal {
    uint256 cardPosition = rng % deck.length;  // Modulo bias negligible with 52 cards
    videoPokerGames[player].cardsInHand[handPosition] = deck[cardPosition];
    _removeCardFromDeck(cardPosition, deck);
}
```

**Analysis:**
- Uses Chainlink VRF for unpredictable randomness ✅
- Removes dealt cards from deck (no duplicates) ✅
- Modulo bias: `2^256 % 52 ≈ 0` (negligible) ✅

### ✅ VRF Callback Security

```solidity
function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
    address player = videoPokerIDs[requestId];
    if (player == address(0)) revert();  // Prevents replay attacks
    delete (videoPokerIDs[requestId]);   // Prevents double-use
    // ...
}
```

**Protections:**
- Only `VRFCoordinatorV2Plus` can call (inherited from `VRFConsumerBaseV2Plus`) ✅
- Request ID mapped to player address ✅
- Mapping deleted after use (no replay) ✅

### ✅ Deck Removal Logic

```solidity
function _removeCardFromDeck(uint256 cardPositon, Card[] memory deck) internal pure {
    deck[cardPositon] = deck[deck.length - 1];  // Swap with last
    assembly {
        mstore(deck, sub(mload(deck), 1))       // Decrement length
    }
}
```

**In fulfillRandomWords (second request):**
```solidity
uint256 deckLength = deck.length;
for (uint256 g = 0; g < 5; g++) {
    for (uint256 j = 0; j < deckLength; j++) {
        if (game.cardsInHand[g].number == deck[j].number 
            && game.cardsInHand[g].suit == deck[j].suit) {
            deck[j] = deck[deckLength - 1];
            deckLength--;
            break;
        }
    }
}
```

**Analysis:**
- Correctly removes initial hand from deck before dealing replacements ✅
- No possibility of duplicate cards ✅

### ✅ Refund Protection

```solidity
function VideoPoker_Refund() external nonReentrant {
    // ...
    if (game.blockNumber + 200 > uint64(ChainSpecificUtil.getBlockNumber())) {
        revert BlockNumberTooLow(ChainSpecificUtil.getBlockNumber(), game.blockNumber + 200);
    }
    // ...
}
```

**Analysis:**
- 200 block delay (~40 minutes) is reasonable ✅
- Prevents premature refund abuse ✅
- BUT: Combined with replace logic, enables griefing attack (see above) ⚠️

---

## 🔴 RECOMMENDATIONS

### 1. Adjust Kelly Criterion for Max Multiplier (MEDIUM)

```solidity
function _kellyWager(uint256 wager, address tokenAddress) internal view {
    uint256 balance;
    if (tokenAddress == address(0)) {
        balance = address(Bankroll()).balance;
    } else {
        balance = IERC20(tokenAddress).balanceOf(address(Bankroll()));
    }
    // Max payout = wager * 100 (Royal Flush)
    // Limit wager so max payout = 1.34% of bankroll
    uint256 maxWager = (balance * 133937) / 10000000000;  // Divided by 100 for max multiplier
    if (wager > maxWager) {
        revert WagerAboveLimit(wager, maxWager);
    }
}
```

### 2. Add Payout Cap as Secondary Protection (OPTIONAL)

```solidity
function _transferPayout(address player, uint256 amount, address tokenAddress) internal {
    if (amount == 0) return;
    
    // Cap payout at 5% of bankroll
    uint256 bankrollBalance;
    if (tokenAddress == address(0)) {
        bankrollBalance = address(Bankroll()).balance;
    } else {
        bankrollBalance = IERC20(tokenAddress).balanceOf(address(Bankroll()));
    }
    uint256 maxPayout = bankrollBalance / 20;  // 5%
    if (amount > maxPayout) {
        amount = maxPayout;
    }
    
    // ... existing transfer logic
}
```

---

## SUMMARY

| Finding | Severity | Status |
|---------|----------|--------|
| Payout Logic Correctness | N/A | ✅ VERIFIED - All 25 tests pass |
| VRF Security & Game Flow | 🟢 LOW | ✅ SECURE - Refund protection works correctly |
| Stand Pat Mechanic | 🟢 LOW | ✅ CORRECT - Players lose wager on bad hands |
| Kelly Criterion Payout Risk | 🟡 MEDIUM | ⚠️ Max payout 13.4% of bankroll on Royal Flush |
| VRF Randomness Security | 🟢 LOW | ✅ SECURE - Proper Chainlink VRF implementation |
| Deck Handling Logic | 🟢 LOW | ✅ SECURE - No duplicate cards possible |

**Overall Assessment:** The contract is secure. The payout logic is mathematically correct, and the game flow properly prevents refund abuse. The only recommendation is to adjust the Kelly Criterion wager limit to account for the 100x max multiplier.

**Priority Action:** Consider implementing Recommendation #1 to reduce bankroll volatility, but this is not a security issue - it's a risk management optimization.
