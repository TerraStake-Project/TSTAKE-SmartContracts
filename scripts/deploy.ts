import hre from "hardhat";

async function main() {
  // Contracts are deployed using the first signer/account by default
  const [deployer] = await hre.ethers.getSigners();

  console.log("Deploying contracts with the account:", deployer.address);

  //////////////////////////////   Deploy TerraStakeToken   //////////////////////////////////////
  const TerraStakeToken = await hre.ethers.deployContract(
    "TerraStakeToken",
    []
  );
  await TerraStakeToken.waitForDeployment();
  console.log(
    "TerraStakeToken is deployed to:",
    await TerraStakeToken.getAddress()
  );

  //////////////////////////////   Deploy TerraStakeGovernance   //////////////////////////////////////
  const TerraStakeGovernance = await hre.ethers.deployContract(
    "TerraStakeGovernance",
    []
  );
  await TerraStakeGovernance.waitForDeployment();
  console.log(
    "TerraStakeGovernance is deployed to:",
    await TerraStakeGovernance.getAddress()
  );

  //////////////////////////////   Deploy TerraStakeAccessControl   //////////////////////////////////////
  const TerraStakeAccessControl = await hre.ethers.deployContract(
    "TerraStakeAccessControl",
    []
  );
  await TerraStakeAccessControl.waitForDeployment();
  console.log(
    "TerraStakeAccessControl is deployed to:",
    await TerraStakeAccessControl.getAddress()
  );

  //////////////////////////////   Deploy TerraStakeProjects   //////////////////////////////////////
  const TerraStakeProjects = await hre.ethers.deployContract(
    "TerraStakeProjects",
    []
  );
  await TerraStakeProjects.waitForDeployment();
  console.log(
    "TerraStakeProjects is deployed to:",
    await TerraStakeProjects.getAddress()
  );

  //////////////////////////////   Deploy TerraStakeStaking   //////////////////////////////////////
  const TerraStakeStaking = await hre.ethers.deployContract(
    "TerraStakeStaking",
    []
  );
  await TerraStakeStaking.waitForDeployment();
  console.log(
    "TerraStakeStaking is deployed to:",
    await TerraStakeStaking.getAddress()
  );

  //////////////////////////////   Deploy TerraStakeRewards   //////////////////////////////////////
  const TerraStakeRewards = await hre.ethers.deployContract(
    "TerraStakeRewards",
    []
  );
  await TerraStakeRewards.waitForDeployment();
  console.log(
    "TerraStakeRewards is deployed to:",
    await TerraStakeRewards.getAddress()
  );

  //////////////////////////////   Deploy ChainlinkDataFeeder   //////////////////////////////////////
  const ChainlinkDataFeeder = await hre.ethers.deployContract(
    "ChainlinkDataFeeder",
    [await TerraStakeProjects.getAddress(), deployer.address, 0]
  );
  await ChainlinkDataFeeder.waitForDeployment();
  console.log(
    "ChainlinkDataFeeder is deployed to:",
    await ChainlinkDataFeeder.getAddress()
  );

  //////////////////////////////   Deploy Proxy of TerraStakeToken   //////////////////////////////////////
  const ProxyOfTerraStakeToken = await hre.ethers.deployContract(
    "TerraStakeProxy",
    [await TerraStakeToken.getAddress(), deployer, "0x"]
  );
  await ProxyOfTerraStakeToken.waitForDeployment();
  console.log(
    "UpgradeableProxy of TerraStakeToken is deployed to:",
    await ProxyOfTerraStakeToken.getAddress()
  );

  //////////////////////////////   Deploy Proxy of TerraStakeToken   //////////////////////////////////////
  const ProxyOfTerraStakeGovernance = await hre.ethers.deployContract(
    "TerraStakeProxy",
    [await TerraStakeGovernance.getAddress(), deployer, "0x"]
  );
  await ProxyOfTerraStakeGovernance.waitForDeployment();
  console.log(
    "UpgradeableProxy of TerraStakeGovernance is deployed to:",
    await ProxyOfTerraStakeGovernance.getAddress()
  );

  //////////////////////////////   Deploy Proxy of TerraStakeToken   //////////////////////////////////////
  const ProxyOfTerraStakeAccessControl = await hre.ethers.deployContract(
    "TerraStakeProxy",
    [await TerraStakeAccessControl.getAddress(), deployer, "0x"]
  );
  await ProxyOfTerraStakeAccessControl.waitForDeployment();
  console.log(
    "UpgradeableProxy of TerraStakeAccessControl is deployed to:",
    await ProxyOfTerraStakeAccessControl.getAddress()
  );

  //////////////////////////////   Deploy Proxy of TerraStakeToken   //////////////////////////////////////
  const ProxyOfTerraStakeProjects = await hre.ethers.deployContract(
    "TerraStakeProxy",
    [await TerraStakeProjects.getAddress(), deployer, "0x"]
  );
  await ProxyOfTerraStakeProjects.waitForDeployment();
  console.log(
    "UpgradeableProxy of TerraStakeProjects is deployed to:",
    await ProxyOfTerraStakeProjects.getAddress()
  );

  //////////////////////////////   Deploy Proxy of TerraStakeToken   //////////////////////////////////////
  const ProxyOfTerraStakeStaking = await hre.ethers.deployContract(
    "TerraStakeProxy",
    [await TerraStakeStaking.getAddress(), deployer, "0x"]
  );
  await ProxyOfTerraStakeStaking.waitForDeployment();
  console.log(
    "UpgradeableProxy of TerraStakeStaking is deployed to:",
    await ProxyOfTerraStakeStaking.getAddress()
  );

  //////////////////////////////   Deploy Proxy of TerraStakeToken   //////////////////////////////////////
  const ProxyOfTerraStakeRewards = await hre.ethers.deployContract(
    "TerraStakeProxy",
    [await TerraStakeRewards.getAddress(), deployer, "0x"]
  );
  await ProxyOfTerraStakeRewards.waitForDeployment();
  console.log(
    "UpgradeableProxy of TerraStakeRewards is deployed to:",
    await ProxyOfTerraStakeRewards.getAddress()
  );
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
