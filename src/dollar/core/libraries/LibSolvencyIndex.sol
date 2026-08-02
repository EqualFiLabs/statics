// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Deterministic AVL index for series-local senior deficits.
/// @dev Books are keyed by the first integer price at which collateral covers the
/// liability. A suffix query at price P aggregates precisely the books whose key is
/// greater than P, then applies a conservative per-book rounding buffer.
library LibSolvencyIndex {
    uint256 internal constant WAD = 1e18;

    struct Node {
        uint256 left;
        uint256 right;
        uint256 height;
        uint256 ownLiabilityWad;
        uint256 ownCollateralWad;
        uint256 ownCount;
        uint256 subtreeLiabilityWad;
        uint256 subtreeCollateralWad;
        uint256 subtreeCount;
        bool exists;
    }

    struct BookContribution {
        uint256 key;
        uint256 liabilityWad;
        uint256 collateralWad;
        bool exists;
    }

    struct Tree {
        mapping(uint256 key => Node node) nodes;
        mapping(bytes32 bookId => BookContribution contribution) books;
        uint256 root;
        uint256 alwaysUnbackedLiabilityWad;
        uint256 alwaysUnbackedCount;
        uint256 activeBooks;
    }

    error UnknownBook(bytes32 bookId);
    error CorruptIndex(uint256 key);

    function update(Tree storage tree, bytes32 bookId, uint256 liabilityWad, uint256 collateralWad) internal {
        BookContribution storage previous = tree.books[bookId];
        if (previous.exists) _removeBook(tree, bookId, previous);
        if (liabilityWad == 0) return;

        uint256 key;
        if (collateralWad == 0) {
            tree.alwaysUnbackedLiabilityWad += liabilityWad;
            tree.alwaysUnbackedCount++;
        } else {
            key = Math.mulDiv(liabilityWad, WAD, collateralWad, Math.Rounding.Ceil);
            tree.root = _insert(tree, tree.root, key, liabilityWad, collateralWad);
        }
        tree.books[bookId] = BookContribution(key, liabilityWad, collateralWad, true);
        tree.activeBooks++;
    }

    function remove(Tree storage tree, bytes32 bookId) internal {
        BookContribution storage storedBook = tree.books[bookId];
        if (!storedBook.exists) revert UnknownBook(bookId);
        _removeBook(tree, bookId, storedBook);
    }

    function deficitAt(Tree storage tree, uint256 priceWad)
        internal
        view
        returns (
            uint256 deficitWad,
            uint256 deficientLiabilityWad,
            uint256 deficientCollateralWad,
            uint256 deficientBookCount
        )
    {
        (deficientLiabilityWad, deficientCollateralWad, deficientBookCount) = _suffix(tree, tree.root, priceWad);
        uint256 collateralValueWad = Math.mulDiv(deficientCollateralWad, priceWad, WAD);
        uint256 roundingBuffer = deficientBookCount == 0 ? 0 : deficientBookCount - 1;
        collateralValueWad = collateralValueWad > roundingBuffer ? collateralValueWad - roundingBuffer : 0;
        uint256 indexedDeficit =
            deficientLiabilityWad > collateralValueWad ? deficientLiabilityWad - collateralValueWad : 0;
        deficitWad = tree.alwaysUnbackedLiabilityWad + indexedDeficit;
        deficientLiabilityWad += tree.alwaysUnbackedLiabilityWad;
        deficientBookCount += tree.alwaysUnbackedCount;
    }

    function bookContribution(Tree storage tree, bytes32 bookId) internal view returns (BookContribution memory) {
        return tree.books[bookId];
    }

    function rootHeight(Tree storage tree) internal view returns (uint256) {
        return _height(tree, tree.root);
    }

    function _removeBook(Tree storage tree, bytes32 bookId, BookContribution storage storedBook) private {
        uint256 liabilityWad = storedBook.liabilityWad;
        uint256 collateralWad = storedBook.collateralWad;
        if (collateralWad == 0) {
            tree.alwaysUnbackedLiabilityWad -= liabilityWad;
            tree.alwaysUnbackedCount--;
        } else {
            tree.root = _removeContribution(tree, tree.root, storedBook.key, liabilityWad, collateralWad);
        }
        tree.activeBooks--;
        delete tree.books[bookId];
    }

    function _insert(Tree storage tree, uint256 root, uint256 key, uint256 liabilityWad, uint256 collateralWad)
        private
        returns (uint256)
    {
        if (root == 0) {
            Node storage created = tree.nodes[key];
            if (created.exists) revert CorruptIndex(key);
            created.exists = true;
            created.height = 1;
            created.ownLiabilityWad = liabilityWad;
            created.ownCollateralWad = collateralWad;
            created.ownCount = 1;
            created.subtreeLiabilityWad = liabilityWad;
            created.subtreeCollateralWad = collateralWad;
            created.subtreeCount = 1;
            return key;
        }
        Node storage node = tree.nodes[root];
        if (key < root) {
            node.left = _insert(tree, node.left, key, liabilityWad, collateralWad);
        } else if (key > root) {
            node.right = _insert(tree, node.right, key, liabilityWad, collateralWad);
        } else {
            node.ownLiabilityWad += liabilityWad;
            node.ownCollateralWad += collateralWad;
            node.ownCount++;
        }
        return _rebalance(tree, root);
    }

    function _removeContribution(
        Tree storage tree,
        uint256 root,
        uint256 key,
        uint256 liabilityWad,
        uint256 collateralWad
    ) private returns (uint256) {
        if (root == 0) revert CorruptIndex(key);
        Node storage node = tree.nodes[root];
        if (key < root) {
            node.left = _removeContribution(tree, node.left, key, liabilityWad, collateralWad);
        } else if (key > root) {
            node.right = _removeContribution(tree, node.right, key, liabilityWad, collateralWad);
        } else {
            if (
                !node.exists || node.ownCount == 0 || node.ownLiabilityWad < liabilityWad
                    || node.ownCollateralWad < collateralWad
            ) revert CorruptIndex(key);
            node.ownLiabilityWad -= liabilityWad;
            node.ownCollateralWad -= collateralWad;
            node.ownCount--;
            if (node.ownCount != 0) return _rebalance(tree, root);

            uint256 left = node.left;
            uint256 right = node.right;
            if (left == 0 || right == 0) {
                uint256 replacement = left == 0 ? right : left;
                delete tree.nodes[root];
                return replacement;
            }
            (uint256 newRight, uint256 successor) = _detachMin(tree, right);
            Node storage successorNode = tree.nodes[successor];
            successorNode.left = left;
            successorNode.right = newRight;
            delete tree.nodes[root];
            return _rebalance(tree, successor);
        }
        return _rebalance(tree, root);
    }

    function _detachMin(Tree storage tree, uint256 root) private returns (uint256 newRoot, uint256 minimum) {
        Node storage node = tree.nodes[root];
        if (node.left == 0) {
            newRoot = node.right;
            minimum = root;
            node.right = 0;
            return (newRoot, minimum);
        }
        (node.left, minimum) = _detachMin(tree, node.left);
        newRoot = _rebalance(tree, root);
    }

    function _suffix(Tree storage tree, uint256 root, uint256 priceWad)
        private
        view
        returns (uint256 liabilityWad, uint256 collateralWad, uint256 count)
    {
        if (root == 0) return (0, 0, 0);
        Node storage node = tree.nodes[root];
        if (root <= priceWad) return _suffix(tree, node.right, priceWad);

        liabilityWad = node.ownLiabilityWad;
        collateralWad = node.ownCollateralWad;
        count = node.ownCount;
        if (node.right != 0) {
            Node storage right = tree.nodes[node.right];
            liabilityWad += right.subtreeLiabilityWad;
            collateralWad += right.subtreeCollateralWad;
            count += right.subtreeCount;
        }
        (uint256 leftLiability, uint256 leftCollateral, uint256 leftCount) = _suffix(tree, node.left, priceWad);
        return (liabilityWad + leftLiability, collateralWad + leftCollateral, count + leftCount);
    }

    function _rebalance(Tree storage tree, uint256 root) private returns (uint256) {
        if (root == 0) return 0;
        _refresh(tree, root);
        int256 balance = _balance(tree, root);
        Node storage node = tree.nodes[root];
        if (balance > 1) {
            if (_balance(tree, node.left) < 0) node.left = _rotateLeft(tree, node.left);
            return _rotateRight(tree, root);
        }
        if (balance < -1) {
            if (_balance(tree, node.right) > 0) node.right = _rotateRight(tree, node.right);
            return _rotateLeft(tree, root);
        }
        return root;
    }

    function _rotateLeft(Tree storage tree, uint256 root) private returns (uint256 pivot) {
        Node storage node = tree.nodes[root];
        pivot = node.right;
        Node storage pivotNode = tree.nodes[pivot];
        node.right = pivotNode.left;
        pivotNode.left = root;
        _refresh(tree, root);
        _refresh(tree, pivot);
    }

    function _rotateRight(Tree storage tree, uint256 root) private returns (uint256 pivot) {
        Node storage node = tree.nodes[root];
        pivot = node.left;
        Node storage pivotNode = tree.nodes[pivot];
        node.left = pivotNode.right;
        pivotNode.right = root;
        _refresh(tree, root);
        _refresh(tree, pivot);
    }

    function _refresh(Tree storage tree, uint256 key) private {
        Node storage node = tree.nodes[key];
        uint256 leftHeight = _height(tree, node.left);
        uint256 rightHeight = _height(tree, node.right);
        node.height = (leftHeight > rightHeight ? leftHeight : rightHeight) + 1;
        node.subtreeLiabilityWad =
            node.ownLiabilityWad + _subtreeLiability(tree, node.left) + _subtreeLiability(tree, node.right);
        node.subtreeCollateralWad =
            node.ownCollateralWad + _subtreeCollateral(tree, node.left) + _subtreeCollateral(tree, node.right);
        node.subtreeCount = node.ownCount + _subtreeCount(tree, node.left) + _subtreeCount(tree, node.right);
    }

    function _balance(Tree storage tree, uint256 key) private view returns (int256) {
        if (key == 0) return 0;
        Node storage node = tree.nodes[key];
        return int256(_height(tree, node.left)) - int256(_height(tree, node.right));
    }

    function _height(Tree storage tree, uint256 key) private view returns (uint256) {
        return key == 0 ? 0 : tree.nodes[key].height;
    }

    function _subtreeLiability(Tree storage tree, uint256 key) private view returns (uint256) {
        return key == 0 ? 0 : tree.nodes[key].subtreeLiabilityWad;
    }

    function _subtreeCollateral(Tree storage tree, uint256 key) private view returns (uint256) {
        return key == 0 ? 0 : tree.nodes[key].subtreeCollateralWad;
    }

    function _subtreeCount(Tree storage tree, uint256 key) private view returns (uint256) {
        return key == 0 ? 0 : tree.nodes[key].subtreeCount;
    }
}
