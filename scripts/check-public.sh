#!/usr/bin/env bash
# Checks that nothing personal or secret is about to be published.
#
#   scripts/check-public.sh [DIR]        scan the files of DIR (default: the repository root)
#   scripts/check-public.sh --history    scan every commit (`git log --all -p`), headers included
#   scripts/check-public.sh --selftest   plant each pattern in a temp dir and check it is caught
#
# Prints `file:line: <pattern name>` for each finding, never the matched text, and exits 1 if
# anything matched (2 on a usage error). In a git checkout only tracked and untracked, non-ignored
# files are scanned; elsewhere every file is.
#
# Patterns: an issued OAuth client id, a JWT, a PEM private key, a /Users/<name> path (other than
# /Users/me), an email address (other than the example and noreply ones), and each line of the
# gitignored `.public-denylist` (fixed strings, case-insensitive; `#` starts a comment). The
# denylist is read from $PUBLIC_DENYLIST, else <DIR>/.public-denylist.
#
# `scripts/check-public.allow` lists exempt paths, one per line: `path-prefix` exempts every
# pattern, `path-prefix<TAB>pattern name` exempts only that one.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

read -r -d '' SCANNER <<'PERL' || true
use strict;
use warnings;

my ($mode, $dir, $denyfile, $allowfile) = @ARGV;

my @patterns = (
    ['issued client id', qr/oaiapp_[A-Za-z0-9]{6,}/],
    ['JWT', qr/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\./],
    ['private key', qr/-----BEGIN [A-Z ]*PRIVATE KEY-----/],
);
my $users_re = qr{/Users/([A-Za-z0-9._-]+)};
my $email_re = qr/[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})/;

sub email_allowed {
    my ($addr, $domain) = @_;
    $addr = lc $addr; $domain = lc $domain;
    return 1 if $domain eq 'example.com' || $domain eq 'example.org';
    return 1 if $addr eq 'noreply@anthropic.com';
    return 1 if $domain eq 'users.noreply.github.com';
    return 0;
}

my @deny;
if (defined $denyfile && -f $denyfile) {
    open my $fh, '<', $denyfile or die "cannot read the denylist\n";
    my $n = 0;
    while (my $l = <$fh>) {
        $n++;
        $l =~ s/\r?\n\z//; $l =~ s/^\s+|\s+\z//g;
        next if $l eq '' || $l =~ /^#/;
        push @deny, ["denylist line $n", lc $l];
    }
}

my @allow;
if (defined $allowfile && -f $allowfile) {
    open my $fh, '<', $allowfile or die "cannot read $allowfile\n";
    while (my $l = <$fh>) {
        $l =~ s/\r?\n\z//;
        next if $l =~ /^\s*(#|$)/;
        my ($p, $name) = split /\t/, $l, 2;
        $p =~ s/^\s+|\s+\z//g;
        push @allow, [$p, defined $name ? $name : ''];
    }
}

sub allowed {
    my ($path, $name) = @_;
    for my $a (@allow) {
        next unless substr($path, 0, length $a->[0]) eq $a->[0];
        return 1 if $a->[1] eq '' || $a->[1] eq $name;
    }
    return 0;
}

my %counts;
my $total = 0;
sub report {
    my ($where, $path, $name) = @_;
    return if defined $path && allowed($path, $name);
    print "$where: $name\n";
    $counts{$name}++;
    $total++;
}

sub scan_line {
    my ($line, $where, $path) = @_;
    for my $p (@patterns) {
        report($where, $path, $p->[0]) if $line =~ $p->[1];
    }
    while ($line =~ /$users_re/g) {
        if ($1 ne 'me') { report($where, $path, 'user home path'); last; }
    }
    while ($line =~ /$email_re/g) {
        my ($addr, $domain) = ($&, $1);
        if (!email_allowed($addr, $domain)) { report($where, $path, 'email address'); last; }
    }
    if (@deny) {
        my $lc = lc $line;
        for my $d (@deny) {
            report($where, $path, $d->[0]) if index($lc, $d->[1]) >= 0;
        }
    }
}

if ($mode eq 'tree') {
    my @files;
    local $/ = "\0";
    while (my $f = <STDIN>) { chomp $f; $f =~ s{^\./}{}; push @files, $f; }
    local $/ = "\n";
    for my $f (@files) {
        scan_line($f, "$f:0", $f);    # the path itself
        my $full = "$dir/$f";
        next if -l $full || !-f $full || -B $full;
        open my $fh, '<', $full or next;
        my $n = 0;
        while (my $line = <$fh>) {
            $n++;
            scan_line($line, "$f:$n", $f);
        }
    }
} else {
    # `git log --all -p` on STDIN: findings are `<commit>:<path>:<line>`, or `<commit>:(header)`
    # for the author, committer and message lines.
    my ($commit, $path, $newline) = ('?', undef, 0);
    my $in_header = 0;
    while (my $line = <STDIN>) {
        if ($line =~ /^commit ([0-9a-f]{7,40})/) {
            $commit = substr($1, 0, 10); $path = undef; $in_header = 1;
            next;
        }
        if ($line =~ /^diff --git /) { $in_header = 0; $path = undef; next; }
        if ($in_header) { scan_line($line, "$commit:(header)", undef); next; }
        if ($line =~ m{^\+\+\+ (?:b/(.*)|/dev/null)$}) { $path = $1; next; }
        next if $line =~ /^--- /;
        if ($line =~ /^@@ -\d+(?:,\d+)? \+(\d+)/) { $newline = $1; next; }
        next unless defined $path;
        if ($line =~ /^\+/) {
            scan_line(substr($line, 1), "$commit:$path:$newline", $path);
            $newline++;
        } elsif ($line =~ /^ /) {
            $newline++;
        }
    }
}

if ($total) {
    my $summary = join ', ', map { "$_: $counts{$_}" } sort keys %counts;
    print STDERR "check-public: $total finding(s) ($summary)\n";
    exit 1;
}
print STDERR "check-public: clean\n";
exit 0;
PERL

# Lists the files of $1, NUL-separated and relative to it.
list_files() {
    local d="$1"
    if [ "$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)" = "$(cd "$d" && pwd -P)" ]; then
        git -C "$d" ls-files -z --cached --others --exclude-standard
    else
        (cd "$d" && find . -type f ! -path './.git/*' ! -name '.public-denylist' -print0)
    fi
}

scan_tree() {
    local d
    d="$(cd "$1" && pwd -P)"
    list_files "$d" | perl -e "$SCANNER" tree "$d" "${PUBLIC_DENYLIST:-$d/.public-denylist}" "$d/scripts/check-public.allow"
}

scan_history() {
    git -C "$root" log --all -p --no-color --no-ext-diff \
        | perl -e "$SCANNER" history "$root" "${PUBLIC_DENYLIST:-$root/.public-denylist}" "$root/scripts/check-public.allow"
}

selftest() {
    local fails=0
    selftest_tmp="$(mktemp -d "${TMPDIR:-/tmp}/check-public.XXXXXX")"
    trap 'rm -rf "$selftest_tmp"' EXIT
    local tmp="$selftest_tmp"
    # Built from pieces so this script never contains a match itself.
    local u="Users" at="@"
    local -a names=('issued client id' 'JWT' 'private key' 'user home path' 'email address' 'denylist line 2')
    local -a samples=(
        "client = \"oaiapp""_Ab12Cd34Ef\""
        "token: eyJ""hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.c2lnbmF0dXJl"
        "-----BEGIN"" RSA PRIVATE KEY-----"
        "see /$u/alice/Documents/notes.txt"
        "write to alice${at}company.io"
        "Signed, ZEBULON Q. TESTPERSON"
    )
    local i out status
    for i in "${!names[@]}"; do
        mkdir -p "$tmp/case$i"
        printf 'line one\n%s\n' "${samples[$i]}" > "$tmp/case$i/file.txt"
        printf '# test denylist\nzebulon q. testperson\n' > "$tmp/case$i/.public-denylist"
        status=0; out="$(PUBLIC_DENYLIST= scan_tree "$tmp/case$i" 2>/dev/null)" || status=$?
        if [ "$status" -eq 1 ] && [ "$out" = "file.txt:2: ${names[$i]}" ]; then
            echo "ok: ${names[$i]} is caught"
        else
            echo "FAIL: ${names[$i]} not caught as expected (exit $status, output: $out)"; fails=$((fails + 1))
        fi
    done

    mkdir -p "$tmp/clean/scripts" "$tmp/clean/allowed"
    printf '%s\n' "/$u/me/dev/remora" "mail user${at}example.com or a${at}example.org" \
        "Co-Authored-By: Claude <noreply${at}anthropic.com>" "123+someone${at}users.noreply.github.com" \
        "oaiapp_ short" > "$tmp/clean/clean.md"
    printf 'oaiapp''_Ab12Cd34Ef\n' > "$tmp/clean/allowed/fake.swift"
    printf 'allowed/\n' > "$tmp/clean/scripts/check-public.allow"
    printf 'zebulon q. testperson\n' > "$tmp/clean/.public-denylist"
    status=0; out="$(PUBLIC_DENYLIST= scan_tree "$tmp/clean" 2>/dev/null)" || status=$?
    if [ "$status" -eq 0 ] && [ -z "$out" ]; then
        echo "ok: a clean file and an allowed path pass"
    else
        echo "FAIL: the clean case was flagged (exit $status, output: $out)"; fails=$((fails + 1))
    fi

    if [ "$fails" -eq 0 ]; then echo "selftest: PASS"; return 0; fi
    echo "selftest: FAIL ($fails)"; return 1
}

case "${1:-}" in
    --selftest) selftest ;;
    --history) scan_history ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' ;;
    -*) echo "usage: $0 [--history] [--selftest] [DIR]" >&2; exit 2 ;;
    *) scan_tree "${1:-$root}" ;;
esac
