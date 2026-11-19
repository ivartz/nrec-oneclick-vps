# Shared validation for shield domain profiles and live dnsmasq rules.
# Domains are passed to remote shells and embedded in dnsmasq syntax; URLs,
# IP addresses, wildcards and shell metacharacters must never reach either.
valid_domain() {
    local domain=$1 label
    local -a labels
    [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" =~ ^[a-zA-Z0-9.-]+$ && ! "$domain" =~ ^[0-9.]+$ ]] || return 1
    [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1
    IFS=. read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}

# Refuse to overlook malformed nftset lines rather than claiming a safe apply.
live_domains() {
    local lines line domain suffix='/4#inet#shield#allow4'
    lines=$($SSH "awk '/^[[:space:]]*nftset[[:space:]]*=/{print}' /etc/dnsmasq.conf") || return 1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ "$line" != nftset=/*"$suffix" ]]; then
            printf 'ERROR: malformed live dnsmasq nftset rule: %s\n' "$line" >&2
            return 1
        fi
        domain=${line#nftset=/}
        domain=${domain%"$suffix"}
        if ! valid_domain "$domain"; then
            printf 'ERROR: invalid live dnsmasq domain: %s\n' "$domain" >&2
            return 1
        fi
        printf '%s\n' "$domain"
    done <<< "$lines"
}

# Print the validated domains in a profile, ignoring whitespace and comments.
profile_domains() {
    local file=$1 line n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%%#*}
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        if ! valid_domain "$line"; then
            printf 'ERROR: invalid domain in %s line %s: %s\n' "$file" "$n" "$line" >&2
            return 1
        fi
        printf '%s\n' "$line"
    done < "$file"
}
