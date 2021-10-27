import pytest
from brownie import config, Contract, ZERO_ADDRESS


@pytest.fixture(scope="function", autouse=True)
def isolate(fn_isolation):
    pass


@pytest.fixture(scope="function", autouse=True)
def isolate(fn_isolation):
    pass


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]

@pytest.fixture
def weth_whale(accounts):
    yield accounts.at("0xc1aae9d18bbe386b102435a8632c8063d31e747c", True)

@pytest.fixture
def mim_whale(accounts):
    yield accounts.at("0x5a6a4d54456819380173272a5e8e9b9904bdf41b", True)

@pytest.fixture
def yvusdc_whale(accounts):
    yield accounts.at("0x5934807cc0654d46755ebd2848840b616256c6ef", True)

@pytest.fixture
def yvcrvseth_whale(accounts):
    yield accounts.at("0xf5bce5077908a1b7370b9ae04adc565ebd643966", True)

@pytest.fixture
def destination_vault(pm, gov, rewards, guardian, management, mim):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(mim, gov, rewards, "", "", guardian, management)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault
    #yield Contract("0x9d409a0A012CFbA9B15F6D4B36Ac57A46966Ab9a")

@pytest.fixture
def token():
    token_address = "0xdCD90C7f6324cfa40d7169ef80b12031770B4325" # yvcrvseth
    yield Contract(token_address)

@pytest.fixture
def yvusdc():
    token_address = "0x5f18c75abdae578b483e5f43f12a39cf75b973a9" # yvusdc
    yield Contract(token_address)

@pytest.fixture
def yvcrvseth():
    token_address = "0xdCD90C7f6324cfa40d7169ef80b12031770B4325" # yvcrvseth
    yield Contract(token_address)

@pytest.fixture
def mim():
    token_address = "0x99d8a9c45b2eca8864373a26d1459e3dff1e17f3"
    yield Contract(token_address)

@pytest.fixture
def amount(accounts, token, user):
    amount = 10_000 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    reserve = accounts.at("0x5934807cc0654d46755ebd2848840b616256c6ef", force=True)
    token.transfer(user, amount, {"from": reserve})
    yield amount


@pytest.fixture
def weth():
    yield Contract("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")


@pytest.fixture
def weth_amout(user, weth):
    weth_amout = 10 ** weth.decimals()
    user.transfer(weth, weth_amout)
    yield weth_amout


@pytest.fixture
def health_check():
    yield Contract("0xddcea799ff1699e98edf118e0629a974df7df012")


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def strategy(
    strategist,
    keeper,
    vault,
    MIMMinterRouterStrategy,
    gov,
    health_check,
    destination_vault
):
    strategy = strategist.deploy(
        MIMMinterRouterStrategy, vault, destination_vault, "yvcrvseth-MIM-Minter",
        "0x0BCa8ebcB26502b013493Bf8fE53aA2B1ED401C1", 75_000, 65_000
    )
    strategy.setKeeper(keeper)

    for i in range(0, 20):
        strat_address = vault.withdrawalQueue(i)
        if ZERO_ADDRESS == strat_address:
            break

        vault.updateStrategyDebtRatio(strat_address, 0, {"from": gov})

    strategy.setHealthCheck(health_check, {"from": gov})
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 0, {"from": gov})

    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
