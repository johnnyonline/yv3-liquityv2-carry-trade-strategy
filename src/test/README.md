// NOTES:
// @dev -- if liquidated, shutdown strategy
// @dev -- stratagiest will need to deploy enough funds to open a trove after deployment
// @dev -- last withdrawal will be stuck until a shutdown (due to Liquity's minimum debt requirement)
// @dev -- will probably not use a factory here -- deploy manually
// @dev -- reporting will be blocked by healthCheck after a redemption/liquidation, until the auction is complete
// @dev -- Should set `leaveDebtBehind` to True since otherwise it could break `_liquidatePosition` bc of no atomic swap. instead, if needed, buy borrow token manually
// @dev we auction on 3 main scenarios:
// 1. liquidation - a loss is expected
// 2. redemption - a profit is expected (unless there's large price swings to the wrong direction and we can't sell the borrow token fast enough)
// 3. profit from lending - a profit is expected
// on (1) liquidation, we block withdrawals to avoid users exiting without taking the loss. gov will need to shutdown the strategy and unblock withdrawals (i.e. we should never get liquidated)

/// if liquidated (with loss):
// 1. AUTO: block withdrawals
// 2. ACTION: shutdown (no need to emergency withdraw)
// 3. KEEPER: auction borrow token
// 4. ACTION: allow loss
// 5. KEEPER: report (reverts on healthCheck until auction is done)
// 6. ACTION: unblock withdrawals

// if redeemed (with profit):
// 1. KEEPER: auction borrow token
// 2. KEEPER: report (reverts on healthCheck until auction is done)

// if redeemed to zombie (with profit):
// 1. KEEPER: adjustZombieTrove (reverts until borrow token is auctioned)
// 2. KEEPER: auction borrow token (adjustZombieTrove succeeds now)
// 3. KEEPER: report (reverts on healthCheck until auction is done)

// if redeemed (with loss - assuming will not happen):
// 1. KEEPER: auction borrow token
// 2. ACTION: allow loss
// 3. KEEPER: report (reverts on healthCheck until auction is done)
// * meaning users can withdraw before the loss is reported

// if redeemed to zombie (with loss - assuming will not happen):
// 1. adjustZombieTrove (reverts until borrow token is auctioned)
// 2. auction borrow token (adjustZombieTrove succeeds now)
// 3. ACTION: allow loss
// 3. report (reverts on healthCheck until auction is done)
// * meaning users can withdraw before the loss is reported