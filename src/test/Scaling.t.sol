
// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "ds-test/test.sol";
import "./../State.sol";
import "./../StateL2.sol";
import "./TestToken.sol";
import "./Vm.sol";
import "./Console.sol";

contract Scaling is DSTest {

    struct Receipt {
        address aAddress;
        address bAddress;
        uint128 amount;
        uint16 seqNo;
        uint32 expiresBy;
    }

    struct Update {
        Receipt receipt;
        bytes aSignature;
        bytes bSignature;
    }

    // `a` is the service provider.
    // We assume that `a` is the one agggregating all receipts
    // and posting them onchain.
    uint256 aPvKey = 0x084154b85f5eec02a721fcfe220e4e871a2c35593c2a46292ad53b8f793c8360;
    address aAddress;

    // users are service requesters
    uint256[] usersPvKey;
    address[] usersAddress;
    Update[] updates;

    StateL2 stateL2;
    TestToken token;
    Vm vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // Configs
    uint256 usersCount = 200;
    uint256 aFunding = 5000000 * 10 ** 18;
    // amount = 3899.791821921342121326
    uint128 dummyCharge = 3899791821921342121326;

    // https://public-grafana.optimism.io/d/9hkhMxn7z/public-dashboard?orgId=1&refresh=5m
    uint256 optimismL1GasPrice = 45;

    function setUsers(uint256 count) internal {
        aAddress = vm.addr(aPvKey);
        string[] memory scriptArgs = new string[](1);
        scriptArgs[0] =  "./pv_key.sh";
        for (uint256 i = 0; i < count; i++) {
            bytes memory raw = vm.ffi(scriptArgs);
            uint256 pvKey = uint256(bytes32(raw));
            usersPvKey.push(pvKey);
        }

        // set addresses
        for (uint256 i = 0; i < usersPvKey.length; i++) {
            usersAddress.push(vm.addr(usersPvKey[i]));
        }
    }

    function setUp() public {
        setUsers(usersCount);

        token = new TestToken(
            "TestToken",
            "TT",
            18
        );

        // mint tokens to `this`
        token.mint(address(this), type(uint256).max);
        stateL2 = new StateL2(address(token));
    }

    function receiptHash(Receipt memory receipt) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    receipt.aAddress,
                    receipt.bAddress,
                    receipt.amount,
                    receipt.seqNo,
                    receipt.expiresBy
                )
            );
    }

    function printBalance(address user) internal view {
        console.log(user, " user's balance: ", stateL2.getAccount(user).balance);
    }

    function printBalances() internal view {
        console.log("a's balance: ", stateL2.getAccount(aAddress).balance);
        for (uint256 i = 0; i < usersAddress.length; i++) {
            console.log(usersAddress[i], "'s balance: ", stateL2.getAccount(usersAddress[i]).balance);
        }
    }

    function registerUsers() internal {
        stateL2.register(aAddress);
        for (uint256 i = 0; i < usersAddress.length; i++) {
            stateL2.register(usersAddress[i]);
        }
    }

    function fundAccount(uint64 index, uint256 amount) internal {
        // transfer token to `state`
        token.transfer(address(stateL2), amount);
        
        // fund `to`'s account in `state`
        stateL2.fundAccount(index);
    }

    function signMsg(bytes32 msgHash, uint256 pvKey) internal returns (bytes memory signature){
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pvKey, msgHash);
        signature = abi.encodePacked(r, s, v);
    }

    function genPostCalldata() internal returns (bytes memory data){
        for (uint256 i = 0; i < updates.length; i++) {
            // console.log("b's index", stateL2.usersIndex(updates[i].receipt.bAddress));
            data = abi.encodePacked(
                data, 
                stateL2.usersIndex(updates[i].receipt.bAddress),
                updates[i].receipt.amount,
                updates[i].aSignature,
                updates[i].bSignature
            );
        }

        data = abi.encodePacked(bytes4(keccak256("post()")), stateL2.usersIndex(aAddress), uint16(updates.length), data);
    }

    function optimismL1Cost(bytes memory data) internal returns (uint256 cost){
        uint256 gasUnits = 0;
        for (uint256 i = 0; i < data.length; i++) {
            if (uint8(data[i]) == 0) {
                gasUnits += 4;
            }else {
                gasUnits += 16;
            }
        }
        cost = (((gasUnits + 2100) * optimismL1GasPrice) * 124 ) / 100;

        console.log("OP l1 gas units raw", gasUnits);
        // console.log("OP l1 gas cost:", cost, " gwei");
    }

    function test1() public {
        registerUsers();

        // fund a's account
        fundAccount(stateL2.usersIndex(aAddress), aFunding);

        printBalances();
        

        for (uint256 i = 0; i < usersAddress.length; i++) {
            // receipts
            Receipt memory r = Receipt({
                aAddress: aAddress,
                bAddress: usersAddress[i],
                amount: dummyCharge,
                seqNo: 1,
                expiresBy: stateL2.currentCycleExpiry()
            });
            bytes32 rHash = receiptHash(r);
            
            Update memory u = Update ({
                receipt: r,
                aSignature: signMsg(rHash, aPvKey),
                bSignature: signMsg(rHash, usersPvKey[i])
            });

            updates.push(u);
        }

        bytes memory callD = genPostCalldata();
        // l1 data cost
        optimismL1Cost(callD);

        uint256 gasL;
        assembly {
            gasL := gas()
        }
        (bool success, ) = address(stateL2).call(callD);
        assembly {
            gasL := sub(gasL, gas())
        }
        console.log("Execution gas units:", gasL);
        assert(success);

        printBalances();
    }



}