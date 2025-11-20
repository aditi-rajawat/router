#!/bin/bash

# Comprehensive regression test for ALL router limits - PRE-PRODUCTION VERSION
# Tests against: https://identity-qal.api.intuit.com/v2/graphql
# Tests: http1_max_request_headers, http1_max_request_buf_size, 
#        http2_max_header_list_size, http_max_request_bytes

set -e

echo "=========================================="
echo "COMPREHENSIVE LIMITS REGRESSION TEST SUITE"
echo "PRE-PRODUCTION ENVIRONMENT"
echo "=========================================="
echo ""

ROUTER_URL="https://identity-qal.api.intuit.com/v2/graphql"
CONTENT_TYPE="Content-Type: application/json"
QUERY='{"query":"{ __typename }"}'

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

test_count=0
pass_count=0
fail_count=0

run_test() {
    local test_num=$1
    local description=$2
    local protocol=$3
    local expected_status=$4
    shift 4
    local curl_args=("$@")
    
    test_count=$((test_count + 1))
    
    echo "----------------------------------------"
    echo "Test $test_num: $description"
    echo "Protocol: $protocol"
    echo "Expected: HTTP $expected_status"
    echo ""
    
    # Create temp files for headers and body
    local response_headers="/tmp/router-test-headers-$test_num.txt"
    local response_body="/tmp/router-test-body-$test_num.txt"
    
    # Run curl and capture status code, headers, and body
    if [ "$protocol" = "http2" ]; then
        status=$(curl --http2 -k "$ROUTER_URL" \
            "${curl_args[@]}" \
            -D "$response_headers" \
            -o "$response_body" \
            -s -w "%{http_code}")
    else
        status=$(curl --http1.1 -k "$ROUTER_URL" \
            "${curl_args[@]}" \
            -D "$response_headers" \
            -o "$response_body" \
            -s -w "%{http_code}")
    fi
    
    # Print response headers
    echo -e "${CYAN}Response Headers:${NC}"
    cat "$response_headers"
    echo ""
    
    # Print response body (truncated if too long)
    echo -e "${CYAN}Response Body:${NC}"
    if [ -s "$response_body" ]; then
        body_size=$(wc -c < "$response_body")
        if [ "$body_size" -gt 500 ]; then
            head -c 500 "$response_body"
            echo ""
            echo "... (truncated, total size: $body_size bytes)"
        else
            cat "$response_body"
        fi
    else
        echo "(empty)"
    fi
    echo ""
    
    # Check result
    if [ "$status" = "$expected_status" ]; then
        echo -e "${GREEN}✅ PASS${NC} - Got HTTP $status"
        pass_count=$((pass_count + 1))
    else
        echo -e "${RED}❌ FAIL${NC} - Expected HTTP $expected_status, got HTTP $status"
        fail_count=$((fail_count + 1))
    fi
    echo ""
    
    # Cleanup temp files
    rm -f "$response_headers" "$response_body"
}

echo "=========================================="
echo "Target Environment: PRE-PRODUCTION"
echo "URL: $ROUTER_URL"
echo ""
echo "Expected Configuration:"
echo "  - http2_max_header_list_size: 10KiB (Router)"
echo "  - http_max_request_bytes: 2MB (default)"
echo ""
echo "NOTE: All requests (API GW → Istio → Router) use HTTP/2"
echo "      HTTP/1.1 limits do not apply in this environment"
echo ""
echo "=========================================="
echo ""

# ==========================================
# SECTION 1: HTTP/2 Header List Size Limit
# ==========================================
echo -e "${BLUE}=========================================="
echo "SECTION 1: http2_max_header_list_size (10KiB)"
echo -e "==========================================${NC}"
echo ""

# Test 1: 3KB total using 3 x 1KB headers (well under 10KiB limit)
headers_3kb=()
for i in $(seq 1 3); do
    headers_3kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 1 "HTTP/2 with 3KB total (3 x 1KB headers, well under 10KiB limit)" "http2" 200 \
    -H "$CONTENT_TYPE" "${headers_3kb[@]}" -d "$QUERY"

# Test 2: 5KB total using 5 x 1KB headers (under 10KiB limit)
headers_5kb=()
for i in $(seq 1 5); do
    headers_5kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 2 "HTTP/2 with 5KB total (5 x 1KB headers, under 10KiB limit)" "http2" 200 \
    -H "$CONTENT_TYPE" "${headers_5kb[@]}" -d "$QUERY"

# Test 3: 8KB total using 8 x 1KB headers (just under 10KiB limit)
headers_8kb=()
for i in $(seq 1 8); do
    headers_8kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 3 "HTTP/2 with 8KB total (8 x 1KB headers, just under 10KiB limit)" "http2" 200 \
    -H "$CONTENT_TYPE" "${headers_8kb[@]}" -d "$QUERY"

# Test 4: 12KB total using 12 x 1KB headers (over 10KiB limit - should fail)
headers_12kb=()
for i in $(seq 1 12); do
    headers_12kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 4 "HTTP/2 with 12KB total (12 x 1KB headers, over 10KiB limit)" "http2" 431 \
    -H "$CONTENT_TYPE" "${headers_12kb[@]}" -d "$QUERY"

# Test 5: 15KB total using 15 x 1KB headers (well over 10KiB limit - should fail)
headers_15kb=()
for i in $(seq 1 15); do
    headers_15kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 5 "HTTP/2 with 15KB total (15 x 1KB headers, well over 10KiB limit)" "http2" 431 \
    -H "$CONTENT_TYPE" "${headers_15kb[@]}" -d "$QUERY"

# Test 6: Test with many headers (header count handling)
headers_40=()
for i in $(seq 1 40); do
    headers_40+=("-H" "X-Header-$i: value$i")
done
run_test 6 "HTTP/2 with 40 headers (testing header count handling)" "http2" 200 \
    -H "$CONTENT_TYPE" "${headers_40[@]}" -d "$QUERY"

# ==========================================
# SECTION 1B: Single Large Header Tests (AWS/ELB per-header limits)
# ==========================================
echo ""
echo -e "${BLUE}=========================================="
echo "SECTION 1B: Single Large Header Tests"
echo "Testing AWS ELB/API Gateway per-header limits"
echo -e "==========================================${NC}"
echo ""

# Test 7: Single 5KB header (under typical AWS limits)
single_5kb=$(head -c 5120 < /dev/zero | tr '\0' 'x')
run_test 7 "HTTP/2 with single 5KB header" "http2" 200 \
    -H "$CONTENT_TYPE" \
    -H "X-Large-Header: $single_5kb" \
    -d "$QUERY"

# Test 8: Single 8KB header (under 10KiB router limit, testing AWS limits)
single_8kb=$(head -c 8192 < /dev/zero | tr '\0' 'x')
run_test 8 "HTTP/2 with single 8KB header (may hit AWS per-header limit)" "http2" 200 \
    -H "$CONTENT_TYPE" \
    -H "X-Large-Header: $single_8kb" \
    -d "$QUERY"

# Test 9: Single 10KB header (at AWS per-header limit)
single_10kb=$(head -c 10240 < /dev/zero | tr '\0' 'x')
run_test 9 "HTTP/2 with single 10KB header (likely blocked by AWS)" "http2" 400 \
    -H "$CONTENT_TYPE" \
    -H "X-Large-Header: $single_10kb" \
    -d "$QUERY"

# Test 10: Single 12KB header (over AWS per-header limit)
single_12kb=$(head -c 12288 < /dev/zero | tr '\0' 'x')
run_test 10 "HTTP/2 with single 12KB header (blocked by AWS)" "http2" 400 \
    -H "$CONTENT_TYPE" \
    -H "X-Large-Header: $single_12kb" \
    -d "$QUERY"

# ==========================================
# SECTION 2: HTTP Request Body Size Limit
# ==========================================
echo ""
echo -e "${BLUE}=========================================="
echo "SECTION 2: http_max_request_bytes (2MB default)"
echo -e "==========================================${NC}"
echo ""

# Small body (1KB - under limit)
small_body=$(head -c 1024 < /dev/zero | tr '\0' 'x' | sed 's/^/{"query":"query{__typename}","variables":{"data":"/' | sed 's/$/"}}/') 
run_test 11 "HTTP/2 with 1KB body (under 2MB limit)" "http2" 200 \
    -H "$CONTENT_TYPE" \
    -d "$small_body"

# Medium body (100KB - under limit)
medium_body='{"query":"{ __typename }","variables":{"data":"'
medium_body+=$(head -c 102400 < /dev/zero | tr '\0' 'x')
medium_body+='"}}'
run_test 12 "HTTP/2 with 100KB body (under 2MB limit)" "http2" 200 \
    -H "$CONTENT_TYPE" \
    -d "$medium_body"

# Large body test - we need to create an actual file to avoid shell limitations
echo "Generating 3MB body for over-limit test..."
large_body_file="/tmp/router-test-large-body.json"
{
    echo -n '{"query":"{ __typename }","variables":{"data":"'
    head -c 3145728 < /dev/zero | tr '\0' 'x'
    echo '"}}'
} > "$large_body_file"

run_test 13 "HTTP/2 with 3MB body (over 2MB limit)" "http2" 413 \
    -H "$CONTENT_TYPE" \
    --data-binary "@$large_body_file"

# Cleanup
rm -f "$large_body_file"

# ==========================================
# Summary
# ==========================================
echo "=========================================="
echo "TEST SUMMARY"
echo "=========================================="
echo ""
echo "Environment: PRE-PRODUCTION"
echo "URL: $ROUTER_URL"
echo ""
echo "Total Tests: $test_count"
echo -e "Passed: ${GREEN}$pass_count${NC}"
echo -e "Failed: ${RED}$fail_count${NC}"
echo ""

if [ $fail_count -eq 0 ]; then
    echo -e "${GREEN}🎉 ALL TESTS PASSED!${NC}"
    echo ""
    echo "Section 1: Multiple Small Headers (Router Total Limit)"
    echo "✅ 3KB total headers (3 x 1KB) - PASS"
    echo "✅ 5KB total headers (5 x 1KB) - PASS"
    echo "✅ 8KB total headers (8 x 1KB, just under limit) - PASS"
    echo "✅ 12KB total headers (12 x 1KB, over limit) - REJECTED with 431"
    echo "✅ 15KB total headers (15 x 1KB, over limit) - REJECTED with 431"
    echo "✅ Header count handling verified (40 headers work)"
    echo ""
    echo "Section 1B: Single Large Headers (AWS Per-Header Limit)"
    echo "✅ Single 5KB header - PASS"
    echo "✅ Single 8KB header - PASS or AWS block"
    echo "✅ Single 10KB header - BLOCKED by AWS with 400"
    echo "✅ Single 12KB header - BLOCKED by AWS with 400"
    echo ""
    echo "Section 2: Request Body Size"
    echo "✅ 1KB body - PASS"
    echo "✅ 100KB body - PASS"
    echo "✅ 3MB body (over 2MB limit) - REJECTED with 413"
    echo ""
    echo "🎯 Router Configuration Verified:"
    echo "   - http2_max_header_list_size: 10KiB [PATCHED!]"
    echo "   - Router successfully handles up to ~8KB total headers"
    echo "   - Router correctly rejects headers >10KiB with HTTP 431"
    echo "   - AWS ELB blocks single headers >8-10KB with HTTP 400"
    echo ""
    echo "🔧 Key Insights:"
    echo "   - Multiple small headers: Tests router's aggregate limit (10KiB)"
    echo "   - Single large header: Tests AWS per-header limit (~8-10KB)"
    echo "   - Router limit (431) vs AWS limit (400) are distinguishable"
    echo ""
    echo "📝 Note: All requests (API GW → Istio → Router) use HTTP/2"
    echo "   HTTP/1.1 limit configurations do not apply"
    echo ""
    echo "✨ Router patch is working correctly!"
    echo "   Successfully enforcing the configured 10KiB limit"
    echo ""
    exit 0
else
    echo -e "${RED}❌ $fail_count TEST(S) FAILED${NC}"
    echo ""
    echo "Please review the failed tests above."
    echo ""
    echo "Common causes:"
    echo "  - AWS API Gateway/ELB blocking very large single headers"
    echo "  - Router http2_max_header_list_size not set to 20KiB"
    echo "  - Wrong router version deployed (needs v2.8.1-http2-header-limit-patch)"
    echo "  - Istio/Envoy limits not configured correctly"
    echo ""
    exit 1
fi

