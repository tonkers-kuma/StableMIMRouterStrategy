import pytest
from brownie import chain, Wei, reverts, Contract, ZERO_ADDRESS

DUST_THRESHOLD = 1e13
def move_funds(vault, dest_vault, strategy, gov, mim, mim_whale):
    print(strategy.name())

    tx = strategy.harvest({"from": gov})
    print(tx.events['Harvested'])
    assert strategy.balanceOfWant() == 0
    assert strategy.valueOfInvestment() > 0

    chain.sleep(360 + 1)
    chain.mine(1)

    prev_value = strategy.valueOfInvestment()
    #produce gains
    mim.transfer(dest_vault, 2_000*(10**mim.decimals()), {"from": mim_whale})
    assert strategy.valueOfInvestment() > prev_value

    tx = strategy.harvest({"from": gov})
    print(tx.events['Harvested'])
    chain.sleep(360 + 1)
    chain.mine(1)
    assert strategy.balanceOfWant() < DUST_THRESHOLD
    assert strategy.valueOfInvestment() > 0
    assert dest_vault.totalAssets() > 0

    total_gain = vault.strategies(strategy).dict()["totalGain"]
    assert total_gain > 0
    assert vault.strategies(strategy).dict()["totalLoss"] < DUST_THRESHOLD

    vault.revokeStrategy(strategy, {"from": gov})
    tx = strategy.harvest({"from": gov})
    print(tx.events['Harvested'])
    total_gain += tx.events["Harvested"]["profit"]
    chain.sleep(360 + 1)
    chain.mine(1)

    assert vault.strategies(strategy).dict()["totalGain"] == total_gain
    assert vault.strategies(strategy).dict()["totalLoss"] < DUST_THRESHOLD
    assert vault.strategies(strategy).dict()["totalDebt"] == 0


def test_original_strategy(strategy, mim, gov, mim_whale, yvcrvsteth_whale, yvcrvsteth, vault, destination_vault):

    vault_token = Contract(vault.token())

    steth = Contract("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84")
    abracadabra = Contract("0x0BCa8ebcB26502b013493Bf8fE53aA2B1ED401C1")
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

    move_funds(vault, destination_vault, strategy, gov, mim, mim_whale)


def test_cloned_strategy(strategy, mim, gov, mim_whale, yvcrvsteth_whale, yvcrvsteth, vault, destination_vault, strategist, rewards, keeper, abracadabra, factory):

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

    clone_tx = factory.cloneMIMMinter(
        vault, strategist, rewards, keeper, destination_vault, abracadabra, 75_000, 60_000, True, "ClonedStrategy", {"from":strategist}
    )

    cloned_strategy = Contract.from_abi(
        "Strategy", clone_tx.events["Cloned"]["clone"], strategy.abi
    )

    vault.updateStrategyDebtRatio(strategy, 0, {"from": gov})

    # Return the funds to the vault
    strategy.harvest({"from": gov})
    vault.addStrategy(cloned_strategy, 10_000, 0, 2 ** 256 - 1, 0, {"from": gov})

    chain.sleep(360)
    chain.mine(1)

    move_funds(
        vault,
        destination_vault,
        cloned_strategy,
        gov,
        mim,
        mim_whale,
    )



def test_double_initialize(strategy, mim, gov, mim_whale, yvcrvsteth_whale, yvcrvsteth, vault, destination_vault, strategist, rewards, keeper, abracadabra, factory):

    clone_tx = factory.cloneMIMMinter(
        vault, strategist, rewards, keeper, destination_vault, abracadabra, 75_000, 60_000, True, "ClonedStrategy", {"from":strategist}
    )

    cloned_strategy = Contract.from_abi(
        "Strategy", clone_tx.events["Cloned"]["clone"], strategy.abi
    )

    # should not be able to call initialize twice
    with reverts("Strategy already initialized"):
        cloned_strategy.initialize(
            vault,
            strategist,
            rewards,
            keeper,
            destination_vault,
            "name",
            {"from": strategist},
        )
