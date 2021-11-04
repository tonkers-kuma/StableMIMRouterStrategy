import pytest
from brownie import Contract, ZERO_ADDRESS, Wei, chain

DUST_THRESHOLD = 10_000
def test_profit_revoke(strategy, mim, gov, mim_whale, yvcrvsteth_whale, yvcrvsteth, vault, destination_vault, abracadabra):
    vault_token = Contract(vault.token())
    bb = Contract(abracadabra.bentoBox())

    initial_amount = 100*(10**yvcrvsteth.decimals())
    # check that address has more than 100 yvusdc
    assert yvcrvsteth.balanceOf(yvcrvsteth_whale) > 100 * (10 ** yvcrvsteth.decimals())

    vault_token.approve(vault, 2 ** 256 - 1, {"from":yvcrvsteth_whale})
    assert destination_vault.totalAssets() == 0

    #we need to add money to abra
    mim.approve(bb, 2**256-1, {"from":mim_whale})
    bb.deposit(mim, mim_whale, abracadabra, 1_000_000*(10**mim.decimals()), 0, {"from":mim_whale})
    vault.deposit(initial_amount/(yvcrvsteth.pricePerShare()/(10**yvcrvsteth.decimals())), {'from': yvcrvsteth_whale})

    assert mim.balanceOf(strategy) == 0

    chain.sleep(360)
    chain.mine(1)

    tx = strategy.harvest({"from": gov})
    print(tx.events['Harvested'])

    total_gain = vault.strategies(strategy).dict()["totalGain"]
    total_loss = vault.strategies(strategy).dict()["totalLoss"]

    assert strategy.balanceOfWant() < DUST_THRESHOLD
    assert strategy.valueOfInvestment() > 0
    assert destination_vault.totalAssets() > 0

    chain.sleep(360)
    chain.mine(1)

    #produce gains
    mim.transfer(destination_vault, 2_000*(10**mim.decimals()), {"from": mim_whale})

    assert strategy.balanceOfWant() < DUST_THRESHOLD
    assert strategy.valueOfInvestment() > 0
    assert destination_vault.totalAssets() > 0

    chain.sleep(360 + 1)
    chain.mine(1)

    vault.revokeStrategy(strategy, {"from": gov})

    chain.sleep(360 + 1)
    chain.mine(1)

    tx = strategy.harvest({"from": gov})
    print(tx.events['Harvested'])

    total_gain += tx.events["Harvested"]["profit"]
    total_loss += tx.events["Harvested"]["loss"]

    chain.sleep(360 + 1)
    chain.mine(1)


    total_gain_ever = vault.strategies(strategy).dict()["totalGain"]
    assert total_gain == total_gain_ever
    assert vault.strategies(strategy).dict()["totalLoss"] < DUST_THRESHOLD
    assert strategy.balanceOfWant() == 0
    assert strategy.valueOfInvestment() < DUST_THRESHOLD
