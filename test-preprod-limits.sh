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
#ROUTER_URL="https://rapidxgqlrouter-qal.api.intuit.com/graphql"
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
echo "  - Infrastructure overhead: ~5KB (API Gateway, Istio, Envoy headers)"
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
echo "Note: ~5KB infrastructure overhead added by API GW/Istio"
echo -e "==========================================${NC}"
echo ""

# Test 1: 3KB test headers → ~8KB total with infrastructure (well under 20KiB)
headers_3kb=()
for i in $(seq 1 3); do
    headers_3kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 1 "HTTP/2 with 3KB test + 5KB infra = ~8KB total (well under 20KiB)" "http2" 200 \
    -H "$CONTENT_TYPE" "${headers_3kb[@]}" -d "$QUERY"

# Test 2: 5KB test headers → ~10KB total with infrastructure (under 20KiB)
headers_5kb=()
for i in $(seq 1 5); do
    headers_5kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 2 "HTTP/2 with 5KB test + 5KB infra = ~10KB total (under 20KiB)" "http2" 200 \
    -H "$CONTENT_TYPE" "${headers_5kb[@]}" -d "$QUERY"

# Test 3: 10KB test headers → ~15KB total with infrastructure (under 20KiB)
headers_10kb=()
for i in $(seq 1 10); do
    headers_10kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 3 "HTTP/2 with 10KB test + 5KB infra = ~15KB total (under 20KiB)" "http2" 200 \
    -H "$CONTENT_TYPE" "${headers_10kb[@]}" -d "$QUERY"

# Test 4: 13KB test headers → ~18KB total with infrastructure (just under 20KiB)
headers_13kb=()
for i in $(seq 1 13); do
    headers_13kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 4 "HTTP/2 with 13KB test + 5KB infra = ~18KB total (just under 20KiB)" "http2" 200 \
    -H "$CONTENT_TYPE" "${headers_13kb[@]}" -d "$QUERY"

# Test 5: 17KB test headers → ~22KB total with infrastructure (OVER 20KiB - should fail)
headers_17kb=()
for i in $(seq 1 17); do
    headers_17kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 5 "HTTP/2 with 17KB test + 5KB infra = ~22KB total (OVER 20KiB)" "http2" 431 \
    -H "$CONTENT_TYPE" "${headers_17kb[@]}" -d "$QUERY"

# Test 6: 20KB test headers → ~25KB total with infrastructure (well over 20KiB - should fail)
headers_20kb=()
for i in $(seq 1 20); do
    headers_20kb+=("-H" "X-Header-$i: $(head -c 1024 < /dev/zero | tr '\0' 'x')")
done
run_test 6 "HTTP/2 with 20KB test + 5KB infra = ~25KB total (well over 20KiB)" "http2" 431 \
    -H "$CONTENT_TYPE" "${headers_20kb[@]}" -d "$QUERY"

# ==========================================
# SECTION 1B: Single Large Header Tests (AWS/ELB per-header limits)
# ==========================================
echo ""
echo -e "${BLUE}=========================================="
echo "SECTION 1B: Single Large Header Tests"
echo "Testing AWS ELB/API Gateway per-header limits"
echo -e "==========================================${NC}"
echo ""

# Test 7: Single 3KB header + 5KB infra = ~8KB total (under limits)
single_3kb=$(head -c 3072 < /dev/zero | tr '\0' 'x')
run_test 7 "HTTP/2 with single 3KB header + 5KB infra = ~8KB total" "http2" 200 \
    -H "$CONTENT_TYPE" \
    -H "X-Large-Header: $single_3kb" \
    -d "$QUERY"

# Test 8: Single 5KB header + 5KB infra = ~10KB total (testing AWS per-header limit)
single_5kb=$(head -c 5120 < /dev/zero | tr '\0' 'x')
run_test 8 "HTTP/2 with single 5KB header + 5KB infra = ~10KB total (may hit AWS)" "http2" 200 \
    -H "$CONTENT_TYPE" \
    -H "X-Large-Header: $single_5kb" \
    -d "$QUERY"

# Test 9: Single 8KB header + 5KB infra = ~13KB total (likely blocked by AWS per-header)
single_8kb=$(head -c 8192 < /dev/zero | tr '\0' 'x')
run_test 9 "HTTP/2 with single 8KB header + 5KB infra = ~13KB total (AWS limit)" "http2" 400 \
    -H "$CONTENT_TYPE" \
    -H "X-Large-Header: $single_8kb" \
    -d "$QUERY"

# Test 10: Single 10KB header + 5KB infra = ~15KB total (blocked by AWS per-header)
single_10kb=$(head -c 10240 < /dev/zero | tr '\0' 'x')
run_test 10 "HTTP/2 with single 10KB header + 5KB infra = ~15KB total (AWS blocks)" "http2" 400 \
    -H "$CONTENT_TYPE" \
    -H "X-Large-Header: $single_10kb" \
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
    echo "✅ Test 1: 3KB test + 5KB infra = ~8KB total - PASS"
    echo "✅ Test 2: 5KB test + 5KB infra = ~10KB total - PASS"
    echo "✅ Test 3: 10KB test + 5KB infra = ~15KB total - PASS"
    echo "✅ Test 4: 13KB test + 5KB infra = ~18KB total (just under) - PASS"
    echo "✅ Test 5: 17KB test + 5KB infra = ~22KB total (over) - REJECTED with 431"
    echo "✅ Test 6: 20KB test + 5KB infra = ~25KB total (over) - REJECTED with 431"
    echo ""
    echo "Section 1B: Single Large Headers (AWS Per-Header Limit)"
    echo "✅ Test 7: Single 3KB header + 5KB infra = ~8KB - PASS"
    echo "✅ Test 8: Single 5KB header + 5KB infra = ~10KB - PASS or AWS block"
    echo "✅ Test 9: Single 8KB header + 5KB infra = ~13KB - BLOCKED by AWS with 400"
    echo "✅ Test 10: Single 10KB header + 5KB infra = ~15KB - BLOCKED by AWS with 400"
    echo ""
    echo "Section 2: Request Body Size"
    echo "✅ Test 11: 1KB body - PASS"
    echo "✅ Test 12: 100KB body - PASS"
    echo "✅ Test 13: 3MB body (over 2MB limit) - REJECTED with 413"
    echo ""
    echo "🎯 Router Configuration Verified:"
    echo "   - http2_max_header_list_size: 20KiB [PATCHED!]"
    echo "   - Infrastructure overhead: ~5KB (auth token, Istio/Envoy headers)"
    echo "   - Effective user header space: ~15KB"
    echo "   - Router successfully handles up to ~18KB total headers"
    echo "   - Router correctly rejects headers >20KiB with HTTP 431"
    echo "   - AWS ELB blocks single headers >8KB with HTTP 400"
    echo ""
    echo "🔧 Key Insights:"
    echo "   - Infrastructure adds ~5KB overhead (authorization: 2.5KB, context: 1KB, etc.)"
    echo "   - Multiple small headers: Tests router's 20KiB aggregate limit"
    echo "   - Single large header: Tests AWS per-header limit (~8-10KB)"
    echo "   - Router limit (431) vs AWS limit (400) are distinguishable"
    echo ""
    echo "📝 Note: All requests (API GW → Istio → Router) use HTTP/2"
    echo "   HTTP/1.1 limit configurations do not apply"
    echo ""
    echo "✨ Router patch is working correctly!"
    echo "   Successfully enforcing the configured 20KiB limit with infrastructure overhead"
    echo ""
    exit 0
else
    echo -e "${RED}❌ $fail_count TEST(S) FAILED${NC}"
    echo ""
    echo "Please review the failed tests above."
    echo ""
    echo "Common causes:"
    echo "  - AWS API Gateway/ELB blocking single headers >8KB (HTTP 400)"
    echo "  - Router http2_max_header_list_size not set to 20KiB (HTTP 431)"
    echo "  - Wrong router version deployed (needs v2.8.1-http2-header-limit-patch)"
    echo "  - Infrastructure overhead (~5KB) not accounted for in tests"
    echo "  - Istio/Envoy limits not configured correctly"
    echo ""
    exit 1
fi

