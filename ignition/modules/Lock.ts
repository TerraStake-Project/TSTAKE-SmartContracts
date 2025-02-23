// This setup uses Hardhat Ignition to manage smart contract deployments.
// Learn more at https://hardhat.org/ignition

import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

// Constants
const JAN_1ST_2030: number = 1893456000;
const ONE_GWEI: bigint = BigInt(1_000_000_000);

const LockModule = buildModule("LockModule", (m) => {
  // Define deployment parameters with defaults
  const unlockTime: number = m.getParameter<number>("unlockTime", JAN_1ST_2030);
  const lockedAmount: bigint = m.getParameter<bigint>("lockedAmount", ONE_GWEI);

  // Deploy Lock contract with parameters
  const lock = m.contract("Lock", [unlockTime], { value: lockedAmount });

  return { lock };
});

export default LockModule;
