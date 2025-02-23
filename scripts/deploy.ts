import hre from "hardhat";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("🚀 Deploying contracts with the account:", deployer.address);

  ////////////////////////////// Deploy ProxyAdmin //////////////////////////////
  const ProxyAdmin = await hre.ethers.getContractFactory("ProxyAdmin");
  const proxyAdmin = await ProxyAdmin.deploy();
  await proxyAdmin.waitForDeployment();
  console.log("✅ ProxyAdmin deployed at:", await proxyAdmin.getAddress());

  ////////////////////////////// Deploy TerraStakeToken //////////////////////////////
  const TerraStakeToken = await hre.ethers.getContractFactory("TerraStakeToken");
  const terraStakeToken = await TerraStakeToken.deploy();
  await terraStakeToken.waitForDeployment();
  console.log("✅ TerraStakeToken deployed at:", await terraStakeToken.getAddress());

  ////////////////////////////// Deploy Proxy for TerraStakeToken //////////////////////////////
  const TransparentProxy = await hre.ethers.getContractFactory("TransparentUpgradeableProxy");
  const terraStakeTokenProxy = await TransparentProxy.deploy(
    await terraStakeToken.getAddress(),
    await proxyAdmin.getAddress(),
    "0x"
  );
  await terraStakeTokenProxy.waitForDeployment();
  console.log("✅ Proxy of TerraStakeToken deployed at:", await terraStakeTokenProxy.getAddress());

  ////////////////////////////// Initialize TerraStakeToken //////////////////////////////
  const initializedToken = TerraStakeToken.attach(await terraStakeTokenProxy.getAddress());
  await initializedToken.initialize(deployer.address, "TerraStake Token", "TSTAKE", 18);
  console.log("✅ TerraStakeToken initialized");

  ////////////////////////////// Deploy TerraStakeGovernance //////////////////////////////
  const TerraStakeGovernance = await hre.ethers.getContractFactory("TerraStakeGovernance");
  const terraStakeGovernance = await TerraStakeGovernance.deploy();
  await terraStakeGovernance.waitForDeployment();
  console.log("✅ TerraStakeGovernance deployed at:", await terraStakeGovernance.getAddress());

  ////////////////////////////// Deploy Proxy for TerraStakeGovernance //////////////////////////////
  const terraStakeGovernanceProxy = await TransparentProxy.deploy(
    await terraStakeGovernance.getAddress(),
    await proxyAdmin.getAddress(),
    "0x"
  );
  await terraStakeGovernanceProxy.waitForDeployment();
  console.log("✅ Proxy of TerraStakeGovernance deployed at:", await terraStakeGovernanceProxy.getAddress());

  ////////////////////////////// Initialize TerraStakeGovernance //////////////////////////////
  const initializedGovernance = TerraStakeGovernance.attach(await terraStakeGovernanceProxy.getAddress());
  await initializedGovernance.initialize(
    deployer.address, await terraStakeTokenProxy.getAddress()
  );
  console.log("✅ TerraStakeGovernance initialized");

  ////////////////////////////// Deploy TerraStakeProjects //////////////////////////////
  const TerraStakeProjects = await hre.ethers.getContractFactory("TerraStakeProjects");
  const terraStakeProjects = await TerraStakeProjects.deploy();
  await terraStakeProjects.waitForDeployment();
  console.log("✅ TerraStakeProjects deployed at:", await terraStakeProjects.getAddress());

  ////////////////////////////// Deploy Proxy for TerraStakeProjects //////////////////////////////
  const terraStakeProjectsProxy = await TransparentProxy.deploy(
    await terraStakeProjects.getAddress(),
    await proxyAdmin.getAddress(),
    "0x"
  );
  await terraStakeProjectsProxy.waitForDeployment();
  console.log("✅ Proxy of TerraStakeProjects deployed at:", await terraStakeProjectsProxy.getAddress());

  ////////////////////////////// Initialize TerraStakeProjects //////////////////////////////
  const initializedProjects = TerraStakeProjects.attach(await terraStakeProjectsProxy.getAddress());
  await initializedProjects.initialize(deployer.address);
  console.log("✅ TerraStakeProjects initialized");

  ////////////////////////////// Deploy TerraStakeStaking //////////////////////////////
  const TerraStakeStaking = await hre.ethers.getContractFactory("TerraStakeStaking");
  const terraStakeStaking = await TerraStakeStaking.deploy();
  await terraStakeStaking.waitForDeployment();
  console.log("✅ TerraStakeStaking deployed at:", await terraStakeStaking.getAddress());

  ////////////////////////////// Deploy Proxy for TerraStakeStaking //////////////////////////////
  const terraStakeStakingProxy = await TransparentProxy.deploy(
    await terraStakeStaking.getAddress(),
    await proxyAdmin.getAddress(),
    "0x"
  );
  await terraStakeStakingProxy.waitForDeployment();
  console.log("✅ Proxy of TerraStakeStaking deployed at:", await terraStakeStakingProxy.getAddress());

  ////////////////////////////// Initialize TerraStakeStaking //////////////////////////////
  const initializedStaking = TerraStakeStaking.attach(await terraStakeStakingProxy.getAddress());
  await initializedStaking.initialize(
    deployer.address, await terraStakeTokenProxy.getAddress(), await terraStakeProjectsProxy.getAddress()
  );
  console.log("✅ TerraStakeStaking initialized");

  ////////////////////////////// Deploy ChainlinkDataFeeder //////////////////////////////
  const ChainlinkDataFeeder = await hre.ethers.getContractFactory("ChainlinkDataFeeder");
  const chainlinkDataFeeder = await ChainlinkDataFeeder.deploy(
    await terraStakeProjectsProxy.getAddress(),
    deployer.address
  );
  await chainlinkDataFeeder.waitForDeployment();
  console.log("✅ ChainlinkDataFeeder deployed at:", await chainlinkDataFeeder.getAddress());

  ////////////////////////////// Deploy TerraStakeRewards //////////////////////////////
  const TerraStakeRewards = await hre.ethers.getContractFactory("TerraStakeRewards");
  const terraStakeRewards = await TerraStakeRewards.deploy();
  await terraStakeRewards.waitForDeployment();
  console.log("✅ TerraStakeRewards deployed at:", await terraStakeRewards.getAddress());

  ////////////////////////////// Deploy Proxy for TerraStakeRewards //////////////////////////////
  const terraStakeRewardsProxy = await TransparentProxy.deploy(
    await terraStakeRewards.getAddress(),
    await proxyAdmin.getAddress(),
    "0x"
  );
  await terraStakeRewardsProxy.waitForDeployment();
  console.log("✅ Proxy of TerraStakeRewards deployed at:", await terraStakeRewardsProxy.getAddress());

  console.log("🚀 All contracts deployed successfully!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
