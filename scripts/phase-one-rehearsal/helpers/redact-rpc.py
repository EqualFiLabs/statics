#!/usr/bin/env python3
"""Keep private upstream endpoint identities out of rehearsal process logs."""
import os
import sys
from urllib.parse import urlsplit


def redact(text, endpoint):
    if not endpoint:
        raise ValueError('configured private upstream required')
    parsed=urlsplit(endpoint)
    for value in (endpoint, parsed.netloc, parsed.hostname):
        if value:text=text.replace(value,'<private-rpc>')
    return text


if __name__=='__main__':
    endpoint=os.environ['ROBINHOOD_MAINNET']
    for line in sys.stdin:
        sys.stdout.write(redact(line,endpoint))
        sys.stdout.flush()
