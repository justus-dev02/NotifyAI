//
//  AgglomerativeClustering.swift
//  NotifyAIServices
//

import Accelerate
import Foundation

/// Average-linkage hierarchical clustering.
///
/// Implemented with the nearest-neighbour-chain algorithm, which needs O(n²) time and
/// memory instead of the O(n³) of the naive approach. Average linkage is "reducible",
/// so the merges found by the chain, sorted by distance, form the exact dendrogram.
enum AgglomerativeClustering {
    enum Metric: Sendable {
        /// 1 − cosine similarity; scale-invariant.
        case cosine
        /// Root-mean-square difference per dimension; keeps the absolute scale, so a
        /// threshold has a fixed meaning (e.g. log-energy units).
        case rootMeanSquare

        func distance(_ lhs: [Float], _ rhs: [Float]) -> Float {
            switch self {
            case .cosine:
                AgglomerativeClustering.cosineDistance(lhs, rhs)
            case .rootMeanSquare:
                (vDSP.distanceSquared(lhs, rhs) / Float(max(lhs.count, 1))).squareRoot()
            }
        }
    }

    /// Assigns a cluster label (0, 1, …) to every vector.
    ///
    /// Clusters are merged while their average distance is below `threshold`. If more
    /// than `maximumClusters` remain, merging continues until that number is reached.
    static func cluster(_ vectors: [[Float]], metric: Metric = .cosine, threshold: Float, maximumClusters: Int) -> [Int] {
        let count = vectors.count
        guard count > 1 else { return Array(repeating: 0, count: count) }

        var distances = distanceMatrix(vectors, metric: metric)
        let merges = nearestNeighborChain(distances: &distances, count: count)
            .sorted { $0.distance < $1.distance }

        // Replay the merges in order of distance with a union-find structure.
        var parent = Array(0..<count)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }

        var clusterCount = count
        for merge in merges {
            guard merge.distance <= threshold || clusterCount > maximumClusters else { break }
            let first = root(merge.first)
            let second = root(merge.second)
            if first != second {
                parent[second] = first
                clusterCount -= 1
            }
        }

        // Relabel roots as 0, 1, 2 … in order of first appearance.
        var labels: [Int: Int] = [:]
        return (0..<count).map { index in
            let clusterRoot = root(index)
            if let label = labels[clusterRoot] { return label }
            let label = labels.count
            labels[clusterRoot] = label
            return label
        }
    }

    struct Merge {
        let first: Int
        let second: Int
        let distance: Float
    }

    static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let lengths = (vDSP.sumOfSquares(lhs) * vDSP.sumOfSquares(rhs)).squareRoot()
        guard lengths > 0 else { return 1 }
        return 1 - vDSP.dot(lhs, rhs) / lengths
    }

    private static func distanceMatrix(_ vectors: [[Float]], metric: Metric) -> [Float] {
        let count = vectors.count
        var matrix = [Float](repeating: 0, count: count * count)
        for row in 0..<count {
            for column in (row + 1)..<count {
                let distance = metric.distance(vectors[row], vectors[column])
                matrix[row * count + column] = distance
                matrix[column * count + row] = distance
            }
        }
        return matrix
    }

    /// Runs the NN-chain algorithm. `distances` is updated in place with Lance-Williams
    /// average-linkage updates; the merged cluster keeps the index of `first`.
    private static func nearestNeighborChain(distances: inout [Float], count: Int) -> [Merge] {
        var isActive = [Bool](repeating: true, count: count)
        var sizes = [Float](repeating: 1, count: count)
        var activeCount = count
        var chain: [Int] = []
        var merges: [Merge] = []
        merges.reserveCapacity(count - 1)

        while activeCount > 1 {
            if chain.isEmpty, let start = isActive.firstIndex(of: true) {
                chain.append(start)
            }
            let current = chain[chain.count - 1]
            let previous = chain.count >= 2 ? chain[chain.count - 2] : nil

            // Nearest active neighbour; ties prefer the previous chain element so the
            // chain always terminates.
            var nearest = previous ?? -1
            var nearestDistance = previous.map { distances[current * count + $0] } ?? .infinity
            for candidate in 0..<count where isActive[candidate] && candidate != current {
                let distance = distances[current * count + candidate]
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearest = candidate
                }
            }

            if nearest == previous, let previous {
                chain.removeLast(2)
                merges.append(Merge(first: previous, second: current, distance: nearestDistance))

                // Lance-Williams update for average linkage; the merged cluster lives at `previous`.
                let sizePrevious = sizes[previous]
                let sizeCurrent = sizes[current]
                let total = sizePrevious + sizeCurrent
                for other in 0..<count where isActive[other] && other != previous && other != current {
                    let distance = (sizePrevious * distances[previous * count + other]
                        + sizeCurrent * distances[current * count + other]) / total
                    distances[previous * count + other] = distance
                    distances[other * count + previous] = distance
                }
                sizes[previous] = total
                isActive[current] = false
                activeCount -= 1
            } else {
                chain.append(nearest)
            }
        }
        return merges
    }
}
