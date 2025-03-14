import { HardhatUserConfig, task } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import dotenv from "dotenv";
import fs from "fs";
import { promisify } from "util";
import path from "path";

dotenv.config();

// Custom clean task to handle Windows permission issues
task("clean-safe", "Cleans the cache and artifacts with extra error handling")
  .setAction(async (_, { config }) => {
    const rimraf = promisify(require("rimraf"));
    const artifactsPath = path.resolve(config.paths.artifacts);
    const cachePath = path.resolve(config.paths.cache);
    
    try {
      console.log("Cleaning artifacts...");
      await rimraf(artifactsPath + "/**", { glob: { ignore: [".gitkeep"] } });
      console.log("Cleaning cache...");
      await rimraf(cachePath + "/**", { glob: { ignore: [".gitkeep"] } });
      console.log("Cleaned successfully!");
    } catch (error) {
      console.log("Error during cleaning:", error);
      console.log("Try closing any applications that might be using these files");
    }
  });

const PRIVATE_KEY = process.env.PRIVATE_KEY || "";
const ALCHEMY_API_KEY = process.env.ALCHEMY_API_KEY || "";
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY || "";

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.28",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          viaIR: true,
        },
      },
    ],
    overrides: {
      // "@uniswap/v3-core/contracts/libraries/TickMath.sol": {
      //   version: "0.8.4", 
      //   settings: {
      //     optimizer: {
      //       enabled: true,
      //       runs: 200,
      //     },
      //   },
      // },
    },
  },
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {},
    // You can add other networks here as needed
  },
  etherscan: {
    apiKey: ETHERSCAN_API_KEY,
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./build-artifacts"
  },
};

export default config;