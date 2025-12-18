// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.2;

import "@etherisc/gif-interface/contracts/components/Oracle.sol";

/// @dev Aggregates multiple oracle source submissions into a single GIF oracle response.
///      Aggregation rule: MEDIAN of numeric severities, then map to S/M/L.
contract FireOracleAggregated is Oracle {
    // --- events ---
    event LogFireOracleRequest(uint256 requestId, string objectName);
    event LogFireOracleSubmission(uint256 requestId, address indexed source, uint16 severity);
    event LogFireOracleFinalized(
        uint256 requestId,
        uint16 medianSeverity,
        bytes1 fireCategory,
        uint256 submissions
    );

    // --- admin / sources ---
    address public admin;
    mapping(address => bool) public isSource;

    modifier onlyAdmin() {
        require(msg.sender == admin, "NOT_ADMIN");
        _;
    }

    modifier onlySource() {
        require(isSource[msg.sender], "NOT_SOURCE");
        _;
    }

    // --- request bookkeeping (kept for parity with your demo oracle) ---
    mapping(string /* objectName */ => uint256) private _requestIdMap;
    uint256 private _requestIds = 0;

    // --- aggregation settings ---
    // quorum = number of independent submissions required before finalizing
    uint8 public quorum;

    // mapping severity -> category:
    // median < mediumThreshold  => 'S'
    // mediumThreshold <= median < largeThreshold => 'M'
    // median >= largeThreshold => 'L'
    uint16 public mediumThreshold; // default 20
    uint16 public largeThreshold;  // default 100

    // --- per-request storage ---
    struct AggState {
        bool finalized;
        uint16[] severities; // small N (e.g., 3 or 5); stored until finalize
    }

    mapping(uint256 => AggState) private _agg;
    mapping(uint256 => mapping(address => bool)) private _submitted; // prevent double-submit per source

    constructor(bytes32 oracleName, address registry)
        Oracle(oracleName, registry)
    {
        admin = msg.sender;
        quorum = 3; // sensible default for demo
        mediumThreshold = 20;
        largeThreshold = 100;

        // If you want the product owner to be able to submit too, you can later add it as a source.
        isSource[msg.sender] = true;
    }

    // --- GIF Oracle interface ---

    function request(uint256 requestId, bytes calldata input)
        external
        override
        onlyQuery
    {
        (string memory objectName) = abi.decode(input, (string));
        _requestIdMap[objectName] = requestId;
        _requestIds += 1;

        // reset aggregation state for this requestId (in case reused in tests)
        delete _agg[requestId];

        emit LogFireOracleRequest(requestId, objectName);
    }

    function cancel(uint256 /* requestId */) external override {
        // optional: implement invalidation; demo keeps it no-op
    }

    // --- Admin controls ---

    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "ZERO_ADMIN");
        admin = newAdmin;
    }

    function setSource(address source, bool allowed) external onlyAdmin {
        require(source != address(0), "ZERO_SOURCE");
        isSource[source] = allowed;
    }

    function setQuorum(uint8 newQuorum) external onlyAdmin {
        require(newQuorum > 0, "QUORUM_ZERO");
        quorum = newQuorum;
    }

    function setThresholds(uint16 newMedium, uint16 newLarge) external onlyAdmin {
        require(newMedium < newLarge, "BAD_THRESHOLDS");
        mediumThreshold = newMedium;
        largeThreshold = newLarge;
    }

    // --- Aggregation flow ---

    /// @notice Submit a numeric severity for a given requestId.
    /// @dev severity is intentionally generic; for demo you can use 0..100.
    function submitSeverity(uint256 requestId, uint16 severity)
        external
        onlySource
    {
        AggState storage st = _agg[requestId];
        require(!st.finalized, "ALREADY_FINALIZED");
        require(!_submitted[requestId][msg.sender], "ALREADY_SUBMITTED");

        // require(severity <= 100, "SEVERITY_OUT_OF_RANGE");

        _submitted[requestId][msg.sender] = true;
        st.severities.push(severity);

        emit LogFireOracleSubmission(requestId, msg.sender, severity);
    }

    /// @notice Finalize aggregation once quorum is met.
    /// @dev Anyone can call; only finalizes once.
    function finalize(uint256 requestId) external {
        AggState storage st = _agg[requestId];
        require(!st.finalized, "ALREADY_FINALIZED");
        require(st.severities.length >= quorum, "QUORUM_NOT_MET");

        uint16 med = _median(st.severities);
        bytes1 cat = _categoryFromSeverity(med);

        st.finalized = true;

        bytes memory output = abi.encode(cat);
        _respond(requestId, output);

        emit LogFireOracleFinalized(requestId, med, cat, st.severities.length);
    }

    // --- views / helpers ---

    function requestId(string calldata objectName) external view returns (uint256) {
        return _requestIdMap[objectName];
    }

    function requestIds() external view returns (uint256) {
        return _requestIds;
    }

    function submissions(uint256 requestId) external view returns (uint256) {
        return _agg[requestId].severities.length;
    }

    function isFinalized(uint256 requestId) external view returns (bool) {
        return _agg[requestId].finalized;
    }

    function _categoryFromSeverity(uint16 severity) internal view returns (bytes1) {
        if (severity < mediumThreshold) return "S";
        if (severity < largeThreshold) return "M";
        return "L";
    }

    /// @dev Median for small arrays. Copies to memory and sorts (insertion sort).
    function _median(uint16[] storage values) internal view returns (uint16) {
        uint256 n = values.length;
        require(n > 0, "NO_VALUES");

        // copy to memory
        uint16[] memory a = new uint16[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = values[i];
        }

        // insertion sort (fine for n=3/5/7)
        for (uint256 i = 1; i < n; i++) {
            uint16 key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = key;
        }

        if (n % 2 == 1) {
            return a[n / 2];
        } else {
            // even-length median: average the two middle values (rounded down)
            uint16 lo = a[(n / 2) - 1];
            uint16 hi = a[n / 2];
            return uint16((uint256(lo) + uint256(hi)) / 2);
        }
    }
}
