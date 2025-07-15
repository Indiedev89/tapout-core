import "dotenv/config";
import { HardhatUserConfig } from "hardhat/config";
import "@typechain/hardhat";
import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-verify";

const {
  PRIVATE_KEY,
  ETHERSCAN_API_KEY,
  BASESCAN_API_KEY,
  ARBITRUM_API_KEY,
  OPTIMISM_API_KEY,
  MEGAETH_API_KEY
} = process.env;

const ChainId = {
  ethereum: 1,
  baseMainnet: 8453,
  baseSepolia: 84532,
  goerli: 5,
  optimismSepolia: 11155420,
  arbitrumSepolia: 421614,
  sepolia: 11155111,
  megaethTestnet: 6342,
};

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.26",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      }
    ],
  },

  etherscan: {
    apiKey: {
      mainnet: ETHERSCAN_API_KEY || "",
      goerli: ETHERSCAN_API_KEY || "",
      sepolia: ETHERSCAN_API_KEY || "",
      baseMainnet: BASESCAN_API_KEY || "",
      baseSepolia: BASESCAN_API_KEY || "",
      arbitrumSepolia: ARBITRUM_API_KEY || "",
      optimismSepolia: OPTIMISM_API_KEY || "",
      megaethTestnet: MEGAETH_API_KEY || "",
    },
    customChains: [
      {
        network: "goerli",
        chainId: ChainId.goerli,
        urls: {
          apiURL: "https://api-goerli.etherscan.io/api",
          browserURL: "https://goerli.etherscan.io",
        },
      },
      {
        network: "optimismSepolia",
        chainId: ChainId.optimismSepolia,
        urls: {
          apiURL: "https://api-sepolia-optimistic.etherscan.io/api",
          browserURL: "https://sepolia-optimism.etherscan.io",
        },
      },
      {
        network: "sepolia",
        chainId: ChainId.sepolia,
        urls: {
          apiURL: "https://api-sepolia.etherscan.io/api",
          browserURL: "https://sepolia.etherscan.io",
        },
      },
      {
        network: "baseMainnet",
        chainId: ChainId.baseMainnet,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org"
        }
      },
      {
        network: "baseSepolia",
        chainId: ChainId.baseSepolia,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org"
        }
      },
      {
        network: "arbitrumSepolia",
        chainId: ChainId.arbitrumSepolia,
        urls: {
          apiURL: "https://api-sepolia.arbiscan.io/api",
          browserURL: "https://sepolia.arbiscan.io"
        }
      },
      {
        network: "megaethTestnet",
        chainId: ChainId.megaethTestnet,
        urls: {
          apiURL: "https://www.oklink.com/api/explorer/v1/contract/verify/async/api",
          browserURL: "https://www.megaexplorer.xyz/",
        },
      },
    ],
  },

  sourcify: {
    enabled: true,
  },

  defaultNetwork: "hardhat",

  networks: {
    hardhat: {},
    localhost: {
      url: "http://127.0.0.1:8545"
    },
    ethereum: {
      url: "wss://mainnet.gateway.tenderly.co",
      chainId: ChainId.ethereum,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
    optimism: {
      url: "https://mainnet.optimism.io",
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
    goerli: {
      url: "https://rpc.ankr.com/eth_goerli",
      chainId: ChainId.goerli,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
    optimismSepolia: {
      url: "https://sepolia.optimism.io",
      chainId: ChainId.optimismSepolia,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
    sepolia: {
      url: "https://sepolia.infura.io/v3/043fe2a7eee34f3d8737e3272161788c",
      chainId: ChainId.sepolia,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
    baseMainnet: {
      url: "https://base-mainnet.g.alchemy.com/v2/ZueyMcFvyu7LewpHDGMIHDVJ7bLBOO-A",
      chainId: ChainId.baseMainnet,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
    baseSepolia: {
      url: "https://sepolia.base.org",
      chainId: ChainId.baseSepolia,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
    arbitrumSepolia: {
      url: "https://arb-sepolia.g.alchemy.com/v2/o-YLW7PyC11n_ccjJLI6ScXRizNJt7Ka",
      chainId: ChainId.arbitrumSepolia,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
    shasta: {
      url: "https://api.shasta.trongrid.io",
      chainId: 123,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
    megaethTestnet: {
      url: "https://carrot.megaeth.com/rpc",
      chainId: ChainId.megaethTestnet,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
  }
};

export default config;