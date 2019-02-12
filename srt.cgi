#!/usr/bin/env python3
# -*- coding: utf-8; -*-
from __future__ import print_function
import sys
import os
import string
import socket
from contextlib import closing
import random
from subprocess import Popen
try:
    from subprocess import DEVNULL
except ImportError:
    DEVNULL = open(os.devnull, 'w')
import cgi
try:
    import urlparse
    from urllib import urlencode
except ImportError:
    from urllib.parse import urlencode
    import urllib.parse as urlparse
import ipaddress # py3 stdlib, else pypi
# from psutil import pid_exists # pypi
# from time import sleep

STRANSMIT = '/usr/bin/srt-live-transmit'

PORT_RANGE = (21000, 22000)

TIMEOUT = 10

INPUTS = {}

def get_address(of_client=False, *candidate_addresses):
    def check_address(address, **attrs):
        try:
            address = unicode(address)
        except NameError:
            pass
        try:
            address = ipaddress.ip_address(address)
        except ValueError:
            return False
        for attr in attrs:
            if getattr(address, attr) != attrs[attr]:
                return False
        return True
    env_vars = ('REMOTE_ADDR',) if of_client else \
               ('SERVER_ADDR', 'SERVER_NAME', 'HTTP_HOST')
    for var in env_vars:
        address = os.environ.get(var, '')

        if var == 'HTTP_HOST':
            address = urlparse.urlparse('http://' + address).hostname
        elif var == 'SERVER_NAME':
            address = address.strip('[]') # "[" ipv6-address "]"

        if check_address(address, is_unspecified=False, is_loopback=False):
            return address

        if var.find('_ADDR') != -1:
            continue

        if not check_address(address, is_unspecified=True):
            address = socket.gethostbyname(address)
            if check_address(address):
                return address
    for address in candidate_addresses:
        if check_address(address, is_unspecified=False, is_loopback=False):
            return address

    http_error(
        error='no suitable {} address found'.format(
            'client' if of_client else 'server'
        )
    )

def try_port(port, address=''):
    with closing(socket.socket(socket.AF_INET, socket.SOCK_DGRAM)) as s:
        try:
            s.bind((address, port))
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            return True
        except socket.error as e:
            return False

def get_port(start, stop, **kwargs):
    bind_address = kwargs.get('bind_address', '')
    port_range = (start, stop + 1)
    try:
        port_range = xrange(*port_range)
    except NameError:
        port_range = range(*port_range)
    for port in random.sample(port_range, len(port_range)):
        if try_port(port, bind_address):
            return port
    return None

def get_passphrase():
    if 'passphrase' not in get_passphrase.__dict__:
        chars = string.ascii_letters + string.digits + '._'
        get_passphrase.passphrase = ''.join(
            [chars[ord(os.urandom(1)) % len(chars)]
             for i in range(16)]
        )
    return get_passphrase.passphrase

def build_srt_uri(addr, port, for_client=False,
                  encryption=False, rendezvous=False):
    srt_params = dict()
    if for_client:
        if not addr:
            return None
        srt_netloc = '{}:{}'.format(addr, port)
    else:
        if addr:
            srt_params['adapter'] = addr
        srt_hostname = rendezvous or ''
        srt_netloc = '{}:{}'.format(srt_hostname, port)
    if encryption:
        srt_params['passphrase'] = get_passphrase()
    if rendezvous:
        srt_params['mode'] = 'rendezvous'
    elif not for_client:
        srt_params['mode'] = 'listener'
    srt_qs = urlencode(srt_params)
    return urlparse.urlunparse(
        ('srt', srt_netloc, '', '', srt_qs, '')
    )

def build_srt_cmdline(input, output):
    try:
        stransmit = STRANSMIT
    except NameError:
        stransmit = 'stransmit'
    cmdline = [stransmit, '-q', '-a:no', input, output]
    if output.find('mode=rendezvous') == -1:
        timeout = '-t:{}'.format(TIMEOUT)
        cmdline[-2:-2] = [timeout, '-taoc:yes']
    return cmdline

def spawn_srt(*args):
    return Popen(
        build_srt_cmdline(*args),
        stdin=DEVNULL, stdout=DEVNULL, stderr=DEVNULL, close_fds=True
    ).pid

def http_test_cgi():
    if os.environ.get('GATEWAY_INTERFACE', '').find('CGI') != 0:
        sys.exit()

def http_error(code = 500, **kwargs):
    print(
        """Status: {}
""".format(str(code))
    )
    if 'error' in kwargs:
        print(kwargs['error'])
    sys.exit()

if __name__ == '__main__':
    http_test_cgi()
    if os.environ.get('REQUEST_METHOD', '') != 'POST':
        http_error(405, error='Method not allowed')
    try:
        form = cgi.FieldStorage()
    except Exception as e:
        http_error(error=e)
    input = INPUTS.get(form.getfirst('input', ''))
    if not input:
        http_error(404, error='Input not found')
    srto = {
        opt: opt in form for opt in ('encryption', 'rendezvous')
    }
    bind_address = get_address()
    srt_port = get_port(*PORT_RANGE, bind_address=bind_address)
    if srto.get('rendezvous', False):
        srto['rendezvous'] = get_address(True, form.getfirst('rendezvous'))
    output = build_srt_uri(bind_address, srt_port, **srto)
    pid = spawn_srt(input, output)
    # sleep(1)
    # if not pid_exists(pid):
    #     http_error(error='stransmit died')
    print(
"""Status: 200
Content-Type: text/plain
Pragma: no-cache
Cache-Control: no-cache, must-revalidate
X-SRT-Pid: {pid}
""".format(pid=pid)
    )
    print(build_srt_uri(bind_address, srt_port, for_client=True, **srto))
