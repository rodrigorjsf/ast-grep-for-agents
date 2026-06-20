import requests


def fetch(url, headers=[]):          # mutable default argument
    print("fetching", url)            # debug print left in
    try:
        r = requests.get(url)         # no timeout
    except:                           # bare except swallows everything
        return None
    if r.status_code == None:         # should be `is None`
        return None
    return r.text
