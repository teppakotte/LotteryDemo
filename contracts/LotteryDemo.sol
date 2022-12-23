//SPDX-License-Identifier: None
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Burnable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

// ChainLink automation setup
import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";

import "hardhat/console.sol";

// Contract declaration
contract LotteryDemo is ERC1155, ERC1155Burnable, AutomationCompatibleInterface {
    
    // burned token ID
    uint256 public constant BURNED = 16;

    // general info
    uint256 public stage; // 0 wait, 1 mint, 2 lottery
    bool public isRevealed;
    address payable public ownerWallet;

    // mint info
    bool public isPublic;

    bytes32 public root; // for WL MerkelProof

    uint256[2] public mintPrices; // 0 WL, 1 Public
    uint256[2] public maxPerWallet; // 0 WL, 1 Public
    mapping(address => uint256) public walletMints; // traking mints by Wallet

    uint256 public mintSupply;
    uint256 public minted;

    // lottery info
    uint256 public lotteryRound; // 0 wait, 1-3 rounds
    uint256[3] public roundWon; // saves winner's token ID

    uint256 public rewardPool;
    uint256[3] public rewards;
    uint256 public chunk; // used for increasing reward on every lottery lose
    uint256 public burned; // amount of tokens burned in lottery

    mapping(uint256 => bool) public tokenEligible; // saves list of eligible tokens on round start
    uint256 private winnerTokenId; // saves winning ID on round start

    // events
    event WLUpdated();
    event MaxPWUpdated(uint256[2] maxPW);
    event PricesUpdated(uint256[2] prices);
    event SupplyUpdated(uint256 supply);

    event StageLaunched(uint256 stage); // 1 - mint, 2 - public mint, 3 - reveal, 4 - lottery
    event RoundLaunched(uint256 round);
    event RoundWins(uint256 round, uint256 tokenId);

    event Minted(uint256 tokenId);
    event MintedMax(address account);
    event Withdrawal(uint256 balance);
    event Reset();

    // ChainLink automation
    address[4] public botAccounts;
    uint256 public interval;
    mapping(uint256 => uint256) public triggerToLastTimeStamp;

    constructor() payable ERC1155("ipfs://QmXGf54iDZTDWSFJS1G3RFNnRf48dJ2uMHBNvDNrXU27oT/{id}.json") {

        // goerli
        // botAccounts = [0xCACAD9c07020d79C2B2216f332Ad668Ef101D62D, 0x17E50d2e24941F0ABFA363C97b4727FEfdD9583B, 0xB3493001E22Ed0bb1AE5fA1D7BFEe935ACA558d5, 0x545baa70122BAC52FE2f45adFc2587A1e6F0F387];
        // hardhat
        botAccounts = [0x70997970C51812dc3A010C7d01b50e0d17dc79C8, 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, 0x90F79bf6EB2c4f870365E785982E1f101E93b906, 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65];
        interval = 1;

        stage = 0;

        mintPrices = [0.1 ether, 0.2 ether];
        maxPerWallet = [1, 3];
        mintSupply = 15;
        minted = 0;

        lotteryRound = 0;
        rewardPool = 0;
        rewards = [0,0,0];
        roundWon = [0,0,0];
        burned = 0;

        // goerli
        // ownerWallet = payable(0x2DFeA4F615d0758817dC160c66f9f23Ba47698AC);
        // hardhat
        ownerWallet = payable(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
        root = 0xac9ea287e28a6b9a01e90b4b5002798329590ddedf39dafb45e1bdd0526b10f3;

        // mint burned tokens by owner for transfering to players
        _mint(ownerWallet, BURNED, mintSupply, "");
    }

    // data update
    function updateWL(bytes32 _root) external {
        root = _root;
        emit WLUpdated();
    }

    function updateSupply(uint256 _supply) external {
        require(_supply <= 15, "Exceeds the amount of generated pictures");
        mintSupply = _supply;
        emit SupplyUpdated(_supply);
    }

    function updatePrices(uint256[2] memory _prices) external {
        require(_prices[0] <= _prices[1], "WL price can't be higher than public price");
        mintPrices = _prices;
        emit PricesUpdated(_prices);
    }

    function updatePerWallet(uint256[2] memory _max) external {
        require(_max[0] <= _max[1], "WL token limit can't be higher than total limit");
        maxPerWallet = _max;
        emit MaxPWUpdated(_max);
    }

    // mint setup
    function launchMint() external {
        require(stage < 1, "WL mint already launched");
        stage = 1;
        emit StageLaunched(1);
    }

    function launchPublicMint() external {
        require(stage == 1, "No ongoing mint");
        require(isPublic == false, "Public mint already launched");
        isPublic = true;
        emit StageLaunched(2);
    }

    function launchReveal() external {
        require(minted >= 3, "Need at least 3 tokens for rarity ranks");
        require(isRevealed == false, "Tokens already revealed");
        isRevealed = true;
        emit StageLaunched(3);
    }

    function uri(uint256 _id) public view override returns(string memory) {
        if (isRevealed) {
        return string(abi.encodePacked("ipfs://QmUqDnzHLiqXbPRzXEMAKFvJcuPRU28cDRbqbRgLLVDPKS/", Strings.toString(_id), ".json"));
        } else {
        return string(abi.encodePacked("ipfs://QmUqDnzHLiqXbPRzXEMAKFvJcuPRU28cDRbqbRgLLVDPKS/0.json"));
        }
    }

    // lottery setup
    function setRewards() internal {
        require(lotteryRound < 1, "Lottery already started, not allowed to change rewards");
        require(minted > 0, "No income from mint, impossible to calculate rewards");

        rewards[0] = (rewardPool/100*20);
        rewards[1] = (rewardPool/100*25);
        rewards[2] = (rewardPool/100*30);
        chunk = rewardPool/100*10/minted;
    }

    function launchLottery() external {
        require(isRevealed == true, "Tokens haven't been revealed yet");
        require(stage < 2, "Lottery already launched");
        setRewards();
        stage = 2;
        emit StageLaunched(4);
    }

    function getRandomNumber() internal view returns(uint) {
        return uint(keccak256(abi.encodePacked(ownerWallet, block.timestamp)));
    }

    function setLotteryRound(uint256 _round, uint256[] memory tokens) external {
        require(_round != lotteryRound, "Round already started");
        require(roundWon[_round - 1] == 0, "Round already won");
        require(stage == 2, "No ongoing lottery");
        
        lotteryRound = _round;
        uint256 index = getRandomNumber() % tokens.length;
        winnerTokenId = tokens[index];
       
        for (uint256 i = 1; i <= minted; i++) if (tokenEligible[i] == true) tokenEligible[i] = false;
        for (uint256 i = 0; i < tokens.length; i++) tokenEligible[tokens[i]] = true;

        emit RoundLaunched(_round);
    }

    // reset
    function resetContract(address[] memory accounts, uint256[][] memory tokens) external {
        
        stage = 0;
        isRevealed = false;

        isPublic = false;
        mintPrices = [0.1 ether, 0.2 ether];
        maxPerWallet = [1, 3];
        mintSupply = 15;
        minted = 0;

        lotteryRound = 0;
        rewards = [0,0,0];
        chunk = 0;
        roundWon = [0,0,0];
        burned = 0;

        for (uint256 i = 0; i < accounts.length; i++) walletMints[accounts[i]] = 0;

        for (uint256 i = 0; i < accounts.length; i++) {

            uint256[] memory tokensCurrent = tokens[i];
            for (uint256 j = 0; j < tokensCurrent.length; j++) _burn(accounts[i], tokensCurrent[j], 1);
        }
        
        _burn(ownerWallet, BURNED, balanceOf(ownerWallet, BURNED));
        _mint(ownerWallet, BURNED, mintSupply, "");

        emit Reset();
    }

    // mint
    function isValid(bytes32[] memory proof, bytes32 leaf) internal view returns (bool) {
       return MerkleProof.verify(proof, root, leaf);
    }

    function wlMint(bytes32[] memory proof) external payable {
        require(stage > 0, "Mint isn't enabled yet");
        require(stage < 2, "Mint has already ended");
        require(isPublic == false, "WhiteList Mint has already ended");
        require(isValid(proof, keccak256(abi.encodePacked(msg.sender))), "You're not allowed to mint");
        require(minted + 1 <= mintSupply, "Exceeds total supply");
        require(walletMints[msg.sender] + 1 <= maxPerWallet[0], "Exceeds max tokens per wallet");
        require(msg.value == mintPrices[0], "Wrong price");

        rewardPool += mintPrices[1];

        walletMints[msg.sender]++;
        minted++;
        uint256 tokenId = minted;
        _mint(msg.sender, tokenId, 1, "0x00");

        emit Minted(tokenId);
        if (walletMints[msg.sender] == maxPerWallet[0]) emit MintedMax(msg.sender);
    }

    function publicMint(uint256 quantity_) external payable {
        require(stage > 0, "Mint isn't enabled yet");
        require(stage < 2, "Mint has already ended");
        require(isPublic == true, "Public Mint isn't enabled yet");
        require(minted + quantity_ <= mintSupply, "Exceeds total supply");
        require(walletMints[msg.sender] + quantity_ <= maxPerWallet[1], "Exceeds max tokens per wallet");
        require(msg.value == quantity_* mintPrices[1], "Wrong price");
        
        
        for (uint256 i = 0; i < quantity_; i++) {
            rewardPool += mintPrices[1];

            walletMints[msg.sender]++;
            minted++;
            uint256 tokenId = minted;
            _mint(msg.sender, tokenId, 1, "0x00");

            emit Minted(tokenId);
            if (walletMints[msg.sender] == maxPerWallet[1]) emit MintedMax(msg.sender);
        }
    }

    function botMint() internal {
        require(stage > 0, "Mint isn't enabled yet");
        require(stage < 2, "Mint has already ended");
        require(minted + 1 <= mintSupply, "Exceeds total supply");

        address botAccount;
        
        for (uint256 i = 0; i < botAccounts.length; i++) {
            botAccount = botAccounts[i];
            if(walletMints[botAccount] < maxPerWallet[1]) {
                botAccount = botAccounts[i];
                break;
            }
        }

        require(walletMints[botAccount] < maxPerWallet[1], "Exceeds max per wallet");
        
        rewardPool += mintPrices[1];

        walletMints[botAccount]++;
        minted++;
        uint256 tokenId = minted;
        _mint(botAccount, tokenId, 1, "0x00");

        emit Minted(tokenId);
        if (walletMints[botAccount] == maxPerWallet[1]) emit MintedMax(botAccount);
    }

    // lottery
    function playLottery(uint256 tokenId_) external {
        require(stage == 2, "Lottery hasn't started yet");
        require(lotteryRound > 0, "First Round hasn't started yet");
        require(roundWon[lotteryRound - 1] == 0, "This round already won");
        require(tokenId_ <= minted, "Token doesn't exist");
        require(balanceOf(msg.sender, tokenId_) > 0, "You don't own this token");
        require(tokenEligible[tokenId_] == true, "This lottery stage for different rarity tokens");

        if (tokenId_ == winnerTokenId) {
            _burn(msg.sender, tokenId_, 1);
            burned++;
            _safeTransferFrom(ownerWallet, msg.sender, BURNED, 1, "0x00");
            roundWon[lotteryRound - 1] = tokenId_;
            payable(msg.sender).transfer(rewards[lotteryRound - 1]);
            emit RoundWins(lotteryRound, tokenId_);
        } else {
            _burn(msg.sender, tokenId_, 1);
            burned++;
            _safeTransferFrom(ownerWallet, msg.sender, BURNED, 1, "0x00");
            rewards[lotteryRound - 1] = rewards[lotteryRound - 1] + chunk;
        }
    }

    function botLottery() internal {
        require(stage == 2, "Lottery hasn't started yet");
        require(lotteryRound > 0, "First Round hasn't started yet");
        require(roundWon[lotteryRound - 1] == 0, "This round already won");

        address botAccount;
        uint256 tokenId;
        
        for (uint256 i = 0; i < botAccounts.length; i++) {
            botAccount = botAccounts[i];
            tokenId = 0;
            for (uint256 j = 1; j < minted; j++) {
                uint256 balance = balanceOf(botAccount, j);
                if(balance > 0 && tokenEligible[j] == true) {
                    botAccount = botAccounts[i];
                    tokenId = j;
                    break;
                }
            }
        if (tokenId > 0) break;
        }

        if (tokenId == 0 || tokenEligible[tokenId] == false) revert("No eligible tokens to play");

        if (tokenId == winnerTokenId) {
            _burn(botAccount, tokenId, 1);
            burned++;
            _safeTransferFrom(ownerWallet, botAccount, BURNED, 1, "0x00");
            roundWon[lotteryRound - 1] = tokenId;
            payable(botAccount).transfer(rewards[lotteryRound - 1]);
            emit RoundWins(lotteryRound, tokenId);
        } else {
            _burn(botAccount, tokenId, 1);
            burned++;
            _safeTransferFrom(ownerWallet, botAccount, BURNED, 1, "0x00");
            rewards[lotteryRound - 1] = rewards[lotteryRound - 1] + chunk;
        }
    }

    // handle funds 

    function addFunds() external payable {
    }

    function withdraw() external {
        require(roundWon[0] != 0, "Round 1 rewards haven't been sent yet");
        require(roundWon[1] != 0, "Round 2 rewards haven't been sent yet");
        require(roundWon[2] != 0, "Round 3 rewards haven't been sent yet");
        payable(msg.sender).transfer(address(this).balance);

        emit Withdrawal(address(this).balance);
    }

    // automation
    function encodeData(uint256 _data) external pure returns (bytes memory) {
        return abi.encodePacked(_data);
    }

    function checkUpkeep(bytes calldata checkData)
    external view returns(bool upkeepNeeded, bytes memory performData) {
        
        uint256 triggerID = abi.decode(checkData, (uint256));
        if (triggerID == 0) {
            require(stage > 0, "Mint isn't enabled yet");
            require(stage < 2, "Mint has already ended");
            require(minted < mintSupply, "Sold out");

            upkeepNeeded = (block.timestamp - triggerToLastTimeStamp[triggerID]) > interval;
            performData = checkData;
        } else if (triggerID == 1) {
            require(stage == 2, "Lottery hasn't started yet");
            require(roundWon[2] == 0 || roundWon[1] == 0 || roundWon[0] == 0, "Lottery has already ended");
            require(lotteryRound > 0, "First Round hasn't started yet");
            require(roundWon[lotteryRound - 1] == 0, "This round already won");

            upkeepNeeded = (block.timestamp - triggerToLastTimeStamp[triggerID]) > interval;
            performData = checkData;
        } else {
            revert("wrong trigger");
        }
    }

    function performUpkeep(bytes calldata performData) external {
        uint256 triggerID = abi.decode(performData, (uint256));

        if (triggerID == 0) {
            require(stage > 0, "Mint isn't enabled yet");
            require(isRevealed == false, "Mint has already ended");
            require(stage < 2, "Mint has already ended");
            require(minted < mintSupply, "Sold out");
            require(isPublic == true, "No auto mints on WL");

            if ((block.timestamp - triggerToLastTimeStamp[triggerID]) > interval) {
                triggerToLastTimeStamp[triggerID] = block.timestamp;
                botMint();
            }
        } else if (triggerID == 1) {
            require(stage == 2, "Lottery hasn't started yet");
            require(roundWon[2] == 0 || roundWon[1] == 0 || roundWon[0] == 0, "Lottery has already ended");
            require(lotteryRound > 0, "First Round hasn't started yet");
            require(roundWon[lotteryRound - 1] == 0, "This round already won");

            if ((block.timestamp - triggerToLastTimeStamp[triggerID]) > interval) {
                triggerToLastTimeStamp[triggerID] = block.timestamp;
                botLottery();
            }
        } else {
            revert("wrong trigger");
        }
    }
}