"""Own API paths: /api/game/..., and nothing forwarded to any other server."""
import main
from helpers import client, new_player


def test_own_paths_and_no_forwarding():
    _, sid, _ = new_player("pth")
    assert client.post("/api/v3/me", data={"sid": sid}).status_code == 200
    assert client.post("/api/game/player", data={"sid": sid}).status_code == 404    # the 1.2.3 player data is gone
    r = client.post("/api/game/config", data={})
    assert r.status_code == 404                      # removed, and not proxied anywhere
    assert client.get("/whatever/else").status_code == 404
    assert not hasattr(main, "proxy_to_original")


def test_actions_are_rate_limited_per_player():
    from systems import too_often, LIMITS
    n, window = LIMITS["/api/v3/survey"]
    assert not any(too_often("rl-a", "/api/v3/survey", now=1000.0 + i) for i in range(n))
    assert too_often("rl-a", "/api/v3/survey", now=1000.0 + n)                 # one too many
    assert not too_often("rl-b", "/api/v3/survey", now=1000.0 + n)             # another player
    assert not too_often("rl-a", "/api/v3/survey", now=1000.0 + window + 1)    # the window moved on
    assert not too_often("rl-a", "/api/v3/state", now=1000.0)                  # reading isn't limited
