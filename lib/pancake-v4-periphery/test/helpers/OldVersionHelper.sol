// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

contract OldVersionHelper is Test {
    function createContractThroughBytecode(string memory path) internal returns (address deployedAddr) {
        bytes memory bytecode = vm.readFileBinary(path);
        assembly {
            deployedAddr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
    }

    function createContractThroughBytecode(string memory path, bytes32 arg0) internal returns (address deployedAddr) {
        bytes memory bytecode = vm.readFileBinary(path);
        assembly {
            // override constructor arguments
            // posOfBytecode + 0x20 + length - 0x20
            let constructorArgStart := add(mload(bytecode), bytecode)
            mstore(constructorArgStart, arg0)
            deployedAddr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
    }

    function createContractThroughBytecode(string memory path, bytes32 arg0, bytes32 arg1, bytes32 arg2)
        internal
        returns (address deployedAddr)
    {
        bytes memory bytecode = vm.readFileBinary(path);
        assembly {
            // override constructor arguments
            // posOfBytecode + 0x20 + length - 0x20 * 3
            let constructorArgStart := sub(add(mload(bytecode), bytecode), 0x40)
            mstore(constructorArgStart, arg0)
            mstore(add(constructorArgStart, 0x20), arg1)
            mstore(add(constructorArgStart, 0x40), arg2)
            // create(value, offset, size)
            deployedAddr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
    }

    function createContractThroughBytecode(string memory path, bytes32 arg0, bytes32 arg1, bytes32 arg2, bytes32 arg3)
        internal
        returns (address deployedAddr)
    {
        bytes memory bytecode = vm.readFileBinary(path);
        assembly {
            // override constructor arguments
            // posOfBytecode + 0x20 + length - 0x20 * 4
            let constructorArgStart := sub(add(mload(bytecode), bytecode), 0x60)
            mstore(constructorArgStart, arg0)
            mstore(add(constructorArgStart, 0x20), arg1)
            mstore(add(constructorArgStart, 0x40), arg2)
            mstore(add(constructorArgStart, 0x60), arg3)
            // create(value, offset, size)
            deployedAddr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
    }

    function toBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}
