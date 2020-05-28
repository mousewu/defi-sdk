// Copyright (C) 2020 Zerion Inc. <https://zerion.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.6.8;
pragma experimental ABIEncoderV2;

import { ERC20 } from "../../ERC20.sol";
import { SafeERC20 } from "../../SafeERC20.sol";
import { Action, AmountType } from "../../Structs.sol";
import { CurveExchangeAdapter } from "../../adapters/curve/CurveExchangeAdapter.sol";
import { InteractiveAdapter } from "../InteractiveAdapter.sol";


/**
 * @dev stableswap contract interface.
 * Only the functions required for CurveExchangeInteractiveAdapter contract are added.
 * The stableswap contract is available here
 * github.com/curvefi/curve-contract/blob/compounded/vyper/stableswap.vy.
 */
/* solhint-disable contract-name-camelcase, func-name-mixedcase */
interface stableswap {
    function exchange_underlying(int128, int128, uint256, uint256) external;
    function get_dy_underlying(int128, int128, uint256) external view returns (uint256);
}
/* solhint-enable contract-name-camelcase, func-name-mixedcase */


/**
 * @title Interactive adapter for Curve protocol (exchange).
 * @dev Implementation of InteractiveAdapter abstract contract.
 * @author Igor Sobolev <sobolev@zerion.io>
 */
contract CurveExchangeInteractiveAdapter is InteractiveAdapter, CurveExchangeAdapter {

    using SafeERC20 for ERC20;

    address internal constant C_SWAP = 0xA2B47E3D5c44877cca798226B7B8118F9BFb7A56;
    address internal constant T_SWAP = 0x52EA46506B9CC5Ef470C5bf89f17Dc28bB35D85C;
    address internal constant Y_SWAP = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address internal constant B_SWAP = 0x79a8C46DeA5aDa233ABaFFD40F3A0A2B1e5A4F27;
    address internal constant S_SWAP = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;
    address internal constant P_SWAP = 0x06364f10B501e868329afBc005b3492902d6C763;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant TUSD = 0x0000000000085d4780B73119b644AE5ecd22b376;
    address internal constant BUSD = 0x4Fabb145d64652a948d72533023f6E7A623C7C53;
    address internal constant SUSD = 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51;
    address internal constant PAX = 0x8E870D67F660D95d5be530380D0eC0bd388289E1;
    uint256 internal constant POOLS_NUMBER = 6;

    /**
     * @notice Exchanges tokens using pool with the best rate.
     * @param tokens Array with one element - token address to be exchanged from.
     * @param amounts Array with one element - token amount to be exchanged from.
     * @param amountTypes Array with one element - amount type.
     * @param data Token address to be exchanged to (ABI-encoded).
     * @return tokensToBeWithdrawn Array with one element - token address to be exchanged to.
     * @dev Implementation of InteractiveAdapter function.
     */
    function deposit(
        address[] memory tokens,
        uint256[] memory amounts,
        AmountType[] memory amountTypes,
        bytes memory data
    )
        public
        payable
        override
        returns (address[] memory tokensToBeWithdrawn)
    {
        require(tokens.length == 1, "CEIA: should be 1 tokens!");
        require(tokens.length == amounts.length, "CEIA: inconsistent arrays!");

        uint256 amount = getAbsoluteAmountDeposit(tokens[0], amounts[0], amountTypes[0]);
        address toToken = abi.decode(data, (address));
        tokensToBeWithdrawn = new address[](1);
        tokensToBeWithdrawn[0] = toToken;

        address[POOLS_NUMBER] memory pools = getCurvePools(tokens[0], toToken);
        int128 i = getTokenIndex(tokens[0]);
        int128 j = getTokenIndex(toToken);

        uint256 rate = 0;
        uint256 index;
        for (uint256 k = 0; k < POOLS_NUMBER; k++) {
            if (pools[k] != address(0)) {
                try stableswap(pools[k]).get_dy_underlying(i, j, amount) returns (uint256 result) {
                    if (result > rate) {
                        rate = result;
                        index = k;
                    }
                } catch Error(string memory reason) {
                    revert(reason);
                } catch (bytes memory) {
                    revert("CEIA: get rate fail![1]");
                }
            }
        }

        ERC20(tokens[0]).safeApprove(pools[index], amount, "CEIA!");
        // solhint-disable-next-line no-empty-blocks
        try stableswap(pools[index]).exchange_underlying(i, j, amount, 0) {
        } catch Error(string memory reason) {
            revert(reason);
        } catch (bytes memory) {
            revert("CEIA: deposit fail!");
        }
    }

    /**
     * @notice Withdraw functionality is not supported.
     * @dev Implementation of InteractiveAdapter function.
     */
    function withdraw(
        address[] memory,
        uint256[] memory,
        AmountType[] memory,
        bytes memory
    )
        public
        payable
        override
        returns (address[] memory)
    {
        revert("CEIA: no withdraw!");
    }

    function getCurvePools(
        address toToken,
        address fromToken
    )
        internal
        pure
        returns (address[POOLS_NUMBER] memory)
    {
        uint256 poolsMask = 63;

        if (toToken == USDT || fromToken == USDT) {
            poolsMask &= 30; // everything except Compound Pool
        } else if (toToken == TUSD || fromToken == TUSD) {
            poolsMask &= 4; // T Pool only
        } else if (toToken == BUSD || fromToken == BUSD) {
            poolsMask &= 8; // bUSD Pool onlly
        } else if (toToken == SUSD || fromToken == SUSD) {
            poolsMask &= 16; // sUSD Pool only
        } else if (toToken == PAX || fromToken == PAX) {
            poolsMask &= 32; // PAX Pool only
        }

        require(poolsMask != 0, "CEIA: bad pools!");

        return [
            poolsMask & 1 == 0 ? address(0) : C_SWAP,
            poolsMask & 2 == 0 ? address(0) : T_SWAP,
            poolsMask & 4 == 0 ? address(0) : Y_SWAP,
            poolsMask & 8 == 0 ? address(0) : B_SWAP,
            poolsMask & 16 == 0 ? address(0) : S_SWAP,
            poolsMask & 32 == 0 ? address(0) : P_SWAP
        ];
    }

    function getTokenIndex(address token) internal pure returns (int128) {
        if (token == DAI) {
            return int128(0);
        } else if (token == USDC) {
            return int128(1);
        } else if (token == USDT) {
            return int128(2);
        } else if (token == TUSD || token == BUSD || token == SUSD || token == PAX) {
            return int128(3);
        } else {
            revert("CEIA: bad token!");
        }
    }
}