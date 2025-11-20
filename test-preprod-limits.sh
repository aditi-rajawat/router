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
echo "  - http2_max_header_list_size: 20KiB (Router)"
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
echo "SECTION 1: http2_max_header_list_size (20KiB)"
echo -e "==========================================${NC}"
echo ""

# Test 1: 5KB total using 5 x 1KB headers
headers_5kb=()
for i in $(seq 1 5); do
    headers_5kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 1 "HTTP/2 with 5KB total (5 x 1KB headers, under AWS limits)" "http2" 200 \
    -H "$CONTENT_TYPE" "${headers_5kb[@]}" -d "$QUERY"

# Test 2: 10KB total using 10 x 1KB headers
headers_10kb=()
for i in $(seq 1 10); do
    headers_10kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 2 "HTTP/2 with 10KB total (10 x 1KB headers, at AWS limit)" "http2" 200 \
    -H "$CONTENT_TYPE" "${headers_10kb[@]}" -d "$QUERY"

# Test 3: 15KB total using 15 x 1KB headers (under 20KiB limit)
headers_15kb=()
for i in $(seq 1 15); do
    headers_15kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 3 "HTTP/2 with 15KB total (15 x 1KB headers, under 20KiB limit)" "http2" 200 \
    -H "$CONTENT_TYPE" "${headers_15kb[@]}" -d "$QUERY"

# Test 4: 19KB total using 19 x 1KB headers (just under 20KiB limit)
headers_19kb=()
for i in $(seq 1 19); do
    headers_19kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 4 "HTTP/2 with 19KB total (19 x 1KB headers, just under 20KiB limit)" "http2" 200 \
    -H "$CONTENT_TYPE" "${headers_19kb[@]}" -d "$QUERY"

# Test 5: 25KB total using 25 x 1KB headers (over 20KiB limit - should fail)
headers_25kb=()
for i in $(seq 1 25); do
    headers_25kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 5 "HTTP/2 with 25KB total (25 x 1KB headers, over 20KiB limit)" "http2" 431 \
    -H "$CONTENT_TYPE" "${headers_25kb[@]}" -d "$QUERY"

# Test 6: 30KB total using 30 x 1KB headers (well over 20KiB limit - should fail)
headers_30kb=()
for i in $(seq 1 30); do
    headers_30kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 6 "HTTP/2 with 30KB total (30 x 1KB headers, well over 20KiB limit)" "http2" 431 \
    -H "$CONTENT_TYPE" "${headers_30kb[@]}" -d "$QUERY"

# Test 7: Test with many headers (header count handling)
headers_40=()
for i in $(seq 1 40); do
    headers_40+=("-H" "X-Header-$i: value$i")
done
run_test 7 "HTTP/2 with 40 headers (testing header count handling)" "http2" 200 \
    -H "$CONTENT_TYPE" "${headers_40[@]}" -d "$QUERY"

# ==========================================
# SECTION 2: HTTP Request Body Size Limit
# ==========================================
echo -e "${BLUE}=========================================="
echo "SECTION 2: http_max_request_bytes (2MB default)"
echo -e "==========================================${NC}"
echo ""

# Small body (1KB - under limit)
small_body=$(head -c 1024 < /dev/zero | tr '\0' 'x' | sed 's/^/{"query":"query{__typename}","variables":{"data":"/' | sed 's/$/"}}/') 
run_test 8 "HTTP/2 with 1KB body (under 2MB limit)" "http2" 200 \
    -H "$CONTENT_TYPE" \
    -d "$small_body"

# Medium body (100KB - under limit)
medium_body='{"query":"{ __typename }","variables":{"data":"'
medium_body+=$(head -c 102400 < /dev/zero | tr '\0' 'x')
medium_body+='"}}'
run_test 9 "HTTP/2 with 100KB body (under 2MB limit)" "http2" 200 \
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

run_test 10 "HTTP/2 with 3MB body (over 2MB limit)" "http2" 413 \
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
    echo "✅ 5KB total headers (5 x 1KB) - PASS"
    echo "✅ 10KB total headers (10 x 1KB) - PASS"
    echo "✅ 15KB total headers (15 x 1KB) - PASS"
    echo "✅ 19KB total headers (19 x 1KB, just under limit) - PASS"
    echo "✅ 25KB total headers (25 x 1KB, over limit) - REJECTED with 431"
    echo "✅ 30KB total headers (30 x 1KB, over limit) - REJECTED with 431"
    echo "✅ http_max_request_bytes (2MB) working correctly"
    echo "✅ Header count handling verified (40 headers work)"
    echo ""
    echo "🎯 Router Configuration Verified:"
    echo "   - http2_max_header_list_size: 20KiB [PATCHED!]"
    echo "   - Router successfully handles up to ~19KB total headers"
    echo "   - Router correctly rejects headers >20KiB with HTTP 431"
    echo "   - Multiple small headers bypass AWS per-header limits"
    echo ""
    echo "🔧 Strategy Used:"
    echo "   - Using multiple 1KB headers instead of one large header"
    echo "   - Each header stays under AWS per-header limit (10-16KB)"
    echo "   - Total size tests router's aggregate limit (20KiB)"
    echo ""
    echo "📝 Note: All requests (API GW → Istio → Router) use HTTP/2"
    echo "   HTTP/1.1 limit configurations do not apply"
    echo ""
    echo "✨ Router patch is working correctly!"
    echo "   Successfully enforcing the configured 20KiB limit"
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

