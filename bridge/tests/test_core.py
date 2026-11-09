from ffr_bridge import protocol
from ffr_bridge.client import normalize_address
from ffr_bridge.core import PROTOCOL, BridgeCore, Status


def connected_core(checked=(), missing=(80201503, 80201504, 80201505)) -> BridgeCore:
    core = BridgeCore(slot_name="P1")
    core.on_room_info({"cmd": "RoomInfo", "seed_name": "S1"})
    core.on_connected({"cmd": "Connected", "slot": 1, "team": 0, "slot_data": {"goal": 0},
                       "checked_locations": list(checked), "missing_locations": list(missing)})
    core.on_received_items({"cmd": "ReceivedItems", "index": 0, "items": []})
    return core


def item(i):
    return {"item": 77000011, "location": i, "player": 2, "flags": 0, "class": "NetworkItem"}


def game_state(checked, goal=False, seed="S1", slot="P1"):
    return {"protocol": PROTOCOL, "seed_name": seed, "slot_name": slot, "checked": list(checked), "goal": goal}


def test_connect_packet_fields():
    p = protocol.connect("P1", "uuid-1", None)
    assert p == {"cmd": "Connect", "password": "", "game": "Final Fantasy Resonance", "name": "P1",
                 "uuid": "uuid-1", "version": {"major": 0, "minor": 6, "build": 9, "class": "Version"},
                 "items_handling": 0b111, "tags": [], "slot_data": True}


def test_decode_rejects_non_packets():
    assert protocol.decode('[{"cmd":"RoomInfo"}]')[0]["cmd"] == "RoomInfo"
    for bad in ('{"cmd":"x"}', '[1]', '[{"nocmd":1}]'):
        try:
            protocol.decode(bad)
        except ValueError:
            continue
        raise AssertionError(bad)


def test_status_progression():
    core = BridgeCore(slot_name="P1")
    assert core.status == Status.DISCONNECTED
    core.on_room_info({"seed_name": "S1"})
    assert core.status == Status.CONNECTED
    core.on_connected({"slot": 1, "team": 0, "checked_locations": [], "missing_locations": []})
    assert core.status == Status.READY  # no ReceivedItems needed (server omits it when empty)


def test_received_items_index_handling():
    core = connected_core()
    assert core.on_received_items({"index": 0, "items": [item(1), item(2)]}) == []
    assert core.on_received_items({"index": 2, "items": [item(3)]}) == []
    assert len(core.received) == 3
    # gap -> Sync, list unchanged
    assert core.on_received_items({"index": 5, "items": [item(9)]}) == [{"cmd": "Sync"}]
    assert len(core.received) == 3
    # full resync after reconnect
    core.on_received_items({"index": 0, "items": [item(1), item(2), item(3), item(4)]})
    assert [i["location"] for i in core.received] == [1, 2, 3, 4]


def test_checks_sent_once_and_confirmed():
    core = connected_core()
    pk = core.packets_for_game_state(game_state([80201503]))
    assert pk == [{"cmd": "LocationChecks", "locations": [80201503]}]
    assert core.packets_for_game_state(game_state([80201503])) == []  # in flight
    core.on_room_update({"checked_locations": [80201503]})
    assert core.packets_for_game_state(game_state([80201503])) == []  # confirmed


def test_in_flight_checks_resent_after_reconnect():
    core = connected_core()
    core.packets_for_game_state(game_state([80201503]))
    core.on_disconnected("lost")
    core.on_connected({"slot": 1, "team": 0, "checked_locations": [], "missing_locations": [80201503]})
    core.on_received_items({"index": 0, "items": []})
    assert core.packets_for_game_state(game_state([80201503])) == [
        {"cmd": "LocationChecks", "locations": [80201503]}]


def test_already_checked_on_server_not_resent():
    core = connected_core(checked=[80201503], missing=[80201504])
    assert core.packets_for_game_state(game_state([80201503])) == []


def test_unknown_locations_never_sent():
    core = connected_core()
    assert core.packets_for_game_state(game_state([99999999])) == []


def test_wrong_seed_or_slot_or_not_ready_sends_nothing():
    core = connected_core()
    assert core.packets_for_game_state(game_state([80201503], seed="OTHER")) == []
    assert core.packets_for_game_state(game_state([80201503], slot="P2")) == []
    assert core.packets_for_game_state(None) == []
    fresh = BridgeCore(slot_name="P1")
    assert fresh.packets_for_game_state(game_state([80201503])) == []


def test_goal_sent_once_per_connection():
    core = connected_core()
    assert {"cmd": "StatusUpdate", "status": 30} in core.packets_for_game_state(game_state([], goal=True))
    assert core.packets_for_game_state(game_state([], goal=True)) == []


def test_new_seed_clears_items():
    core = connected_core()
    core.on_received_items({"index": 0, "items": [item(1)]})
    core.on_room_info({"seed_name": "S2"})
    assert core.received == []


def test_bridge_state_snapshot():
    core = connected_core()
    core.on_received_items({"index": 0, "items": [item(1)]})
    core.add_message("hello")
    st = core.bridge_state()
    assert st["protocol"] == PROTOCOL and st["status"] == Status.READY
    assert st["seed_name"] == "S1" and st["slot_name"] == "P1" and st["slot"] == 1
    assert st["items"] == [{"item": 77000011, "location": 1, "player": 2, "flags": 0,
                            "item_name": "Item 77000011", "sender": "Player 2", "location_name": "Location 1"}]
    assert st["events"] == [] and isinstance(st["epoch"], int)
    assert st["messages"] == [{"id": 1, "text": "hello"}]
    assert st["slot_data"] == {"goal": 0}


def test_bridge_state_unbound_before_auth():
    core = BridgeCore(slot_name="P1")
    core.on_room_info({"seed_name": "S1"})
    assert core.bridge_state()["seed_name"] is None


def test_messages_capped():
    core = BridgeCore(slot_name="P1")
    for i in range(80):
        core.add_message(str(i))
    assert len(core.messages) == 50 and core.messages[-1]["id"] == 80


def test_normalize_address():
    assert normalize_address("localhost:38281") == ("ws://localhost:38281", False)
    assert normalize_address("archipelago.gg:12345") == ("ws://archipelago.gg:12345", False)
    assert normalize_address("wss://archipelago.gg:12345") == ("wss://archipelago.gg:12345", True)
    assert normalize_address("localhost")[0] == "ws://localhost:38281"
    try:
        normalize_address("http://x:1")
    except ValueError:
        pass
    else:
        raise AssertionError("http accepted")


def test_print_json_rendering():
    names = protocol.NameLookup()
    names.load_connected({"players": [{"slot": 1, "alias": "Alice"}],
                          "slot_info": {"1": {"game": "Final Fantasy Resonance"}}})
    names.load_data_package({"data": {"games": {"Final Fantasy Resonance": {
        "item_name_to_id": {"Potion": 77000011}, "location_name_to_id": {"Chest": 80201503}}}}})
    text = protocol.render_print_json({"data": [
        {"type": "player_id", "text": "1"}, {"text": " found "},
        {"type": "item_id", "text": "77000011", "player": 1}, {"text": " at "},
        {"type": "location_id", "text": "80201503", "player": 1}]}, names)
    assert text == "Alice found Potion at Chest"


def test_refusal_messages():
    from ffr_bridge.client import describe_refusal
    assert "check the slot name" in describe_refusal(["InvalidSlot"])
    assert "password" in describe_refusal(["InvalidPassword"])
    assert describe_refusal(["SomethingNew"]) == "SomethingNew"
    assert describe_refusal([]) == "no reason given"


# --- DeathLink ------------------------------------------------------------------------

import time  # noqa: E402


def death_core(slot_data_death_link=1, override=None) -> BridgeCore:
    core = BridgeCore(slot_name="P1", death_link_override=override)
    core.on_room_info({"seed_name": "S1"})
    core.on_connected({"slot": 1, "team": 0, "slot_data": {"death_link": slot_data_death_link},
                       "checked_locations": [], "missing_locations": [80201503]})
    return core


def death_state(count, last_time=None, cause=None):
    st = game_state([])
    st["deaths"] = {"count": count, "last_time": time.time() if last_time is None else last_time}
    if cause:
        st["deaths"]["last_cause"] = cause
    return st


def bounces(packets):
    return [p for p in packets if p["cmd"] == "Bounce"]


def test_death_link_packets():
    assert protocol.connect("P1", "u", None, ["DeathLink"])["tags"] == ["DeathLink"]
    assert protocol.connect_update(["DeathLink"]) == {"cmd": "ConnectUpdate", "tags": ["DeathLink"]}
    b = protocol.death_bounce("P1", "P1 died", 12.5)
    assert b == {"cmd": "Bounce", "tags": ["DeathLink"], "data": {"time": 12.5, "source": "P1", "cause": "P1 died"}}


def test_death_link_follows_slot_data_and_override():
    assert death_core(1).death_link is True
    assert death_core(0).death_link is False
    assert death_core(1, override=False).death_link is False
    assert death_core(0, override=True).death_link is True
    assert BridgeCore(slot_name="P1").bridge_state()["death_link"]["enabled"] is False


def test_first_observed_death_count_is_baseline_not_sent():
    core = death_core()
    assert bounces(core.packets_for_game_state(death_state(3))) == []   # deaths before the bridge started
    sent = bounces(core.packets_for_game_state(death_state(4, cause="P1 fell")))
    assert len(sent) == 1 and sent[0]["data"]["source"] == "P1" and sent[0]["data"]["cause"] == "P1 fell"
    assert bounces(core.packets_for_game_state(death_state(4))) == []    # same count: nothing new


def test_default_cause_and_game_restart_resets_baseline():
    core = death_core()
    core.packets_for_game_state(death_state(2))
    assert bounces(core.packets_for_game_state(death_state(0))) == []    # game restarted, counter reset
    sent = bounces(core.packets_for_game_state(death_state(1)))
    assert sent[0]["data"]["cause"] == "P1's party was wiped out."


def test_stale_or_disabled_deaths_not_sent():
    core = death_core()
    core.packets_for_game_state(death_state(0))
    assert bounces(core.packets_for_game_state(death_state(1, last_time=time.time() - 3600))) == []
    off = death_core(0)
    off.packets_for_game_state(death_state(0))
    assert bounces(off.packets_for_game_state(death_state(1))) == []
    assert bounces(off.packets_for_game_state(death_state(1))) == []    # not sent later when re-enabled either


def test_bounced_death_recorded_and_echo_ignored():
    core = death_core()
    core.packets_for_game_state(death_state(0))
    own = bounces(core.packets_for_game_state(death_state(1)))[0]
    assert core.on_bounced({"cmd": "Bounced", "tags": ["DeathLink"], "data": own["data"]}) is None  # echo
    d = core.on_bounced({"cmd": "Bounced", "tags": ["DeathLink"],
                         "data": {"time": time.time() + 1, "source": "P2", "cause": "P2 was eaten"}})
    assert d == {"id": 1, "source": "P2", "cause": "P2 was eaten"}
    st = core.bridge_state()["death_link"]
    assert st["enabled"] is True and st["deaths"] == [d] and isinstance(st["session"], int)
    assert core.messages[-1]["text"] == "DeathLink: P2 was eaten"


def test_bounced_ignored_without_tag_or_when_disabled():
    core = death_core()
    assert core.on_bounced({"cmd": "Bounced", "tags": ["Other"], "data": {"time": 1.0, "source": "P2"}}) is None
    assert core.on_bounced({"cmd": "Bounced", "data": {"time": 1.0, "source": "P2"}}) is None
    assert core.on_bounced({"cmd": "Bounced", "tags": ["DeathLink"], "data": {"source": "P2"}}) is None
    assert death_core(0).on_bounced({"cmd": "Bounced", "tags": ["DeathLink"],
                                     "data": {"time": 1.0, "source": "P2"}}) is None


def test_received_deaths_capped_with_increasing_ids():
    core = death_core()
    for i in range(30):
        core.on_bounced({"cmd": "Bounced", "tags": ["DeathLink"], "data": {"time": 100.0 + i, "source": "P2"}})
    assert len(core.deaths_in) == 20 and core.deaths_in[-1]["id"] == 30


# --- In-game message events -----------------------------------------------------------

def two_game_names():
    names = protocol.NameLookup()
    names.load_connected({"players": [{"slot": 1, "alias": "Alice"}, {"slot": 2, "name": "Bob"}],
                          "slot_info": {"1": {"game": "Final Fantasy Resonance"}, "2": {"game": "APQuest"}}})
    names.load_data_package({"data": {"games": {
        "Final Fantasy Resonance": {"item_name_to_id": {"Potion x3": 77000013}, "location_name_to_id": {"Chest": 80201503}},
        "APQuest": {"item_name_to_id": {"Sword": 1}, "location_name_to_id": {"Tree": 42}}}}})
    return names


def hint(receiving, finder):
    return {"cmd": "PrintJSON", "type": "Hint", "receiving": receiving,
            "item": {"item": 77000013 if receiving == 1 else 1, "location": 42 if finder == 2 else 80201503,
                     "player": finder, "flags": 1},
            "data": [{"text": "[Hint]: something"}]}


def test_print_json_classification():
    assert protocol.classify_print_json(hint(1, 2), 1) == "hint"      # an item we receive
    assert protocol.classify_print_json(hint(2, 1), 1) == "hint"      # an item in our world
    assert protocol.classify_print_json(hint(2, 3), 1) is None        # other players only
    assert protocol.classify_print_json(hint(1, 2), None) is None     # not authenticated
    assert protocol.classify_print_json({"type": "Chat", "data": []}, 1) == "chat"
    assert protocol.classify_print_json({"type": "ServerChat", "data": []}, 1) == "chat"
    for other in ("ItemSend", "Join", "Part", "Tutorial", "CommandResult", None):
        assert protocol.classify_print_json({"type": other, "data": []}, 1) is None


def test_print_json_events_and_log_messages():
    core = connected_core()
    names = two_game_names()
    core.on_print_json(hint(1, 2), names)
    core.on_print_json({"cmd": "PrintJSON", "type": "ItemSend", "data": [{"text": "Bob found Sword"}]}, names)
    core.on_print_json({"cmd": "PrintJSON", "type": "Chat", "data": [{"text": "Bob: hi"}]}, names)
    assert [m["text"] for m in core.messages] == ["[Hint]: something", "Bob found Sword", "Bob: hi"]
    assert core.events == [{"id": 1, "kind": "hint", "text": "Hint: your Potion x3 is at Tree (Bob's world)"},
                           {"id": 2, "kind": "chat", "text": "Bob: hi"}]
    st = core.bridge_state(names)
    assert st["events"] == core.events and st["epoch"] == core.epoch


def test_events_capped_and_epoch_differs_per_core():
    core = BridgeCore(slot_name="P1")
    for i in range(130):
        core.add_event("chat", str(i))
    assert len(core.events) == 100 and core.events[0]["id"] == 31 and core.events[-1]["id"] == 130
    assert BridgeCore(slot_name="P1").epoch != core.epoch


def test_received_items_carry_names():
    core = connected_core()
    names = two_game_names()
    core.on_received_items({"cmd": "ReceivedItems", "index": 0, "items": [
        {"item": 77000013, "location": 42, "player": 2, "flags": 0},          # found by Bob in APQuest
        {"item": 77000013, "location": 80201503, "player": 1, "flags": 0},    # found in our own world
        {"item": 77000013, "location": -2, "player": 0, "flags": 0},          # /send from the server
        {"item": 99, "location": 7, "player": 9, "flags": 0}]})               # unknown everything
    st = core.bridge_state(names)
    got = [(i["item_name"], i["sender"], i["location_name"]) for i in st["items"]]
    assert got == [("Potion x3", "Bob", "Tree"), ("Potion x3", "Alice", "Chest"), ("Potion x3", "Archipelago", ""),
                   ("Item 99", "Player 9", "Location 7")]
    assert st["items"][0]["item"] == 77000013 and st["players"] == {"1": "Alice", "2": "Bob"}
    assert core.received[0] == {"item": 77000013, "location": 42, "player": 2, "flags": 0}  # raw list unchanged


def test_compact_hint_texts():
    names = two_game_names()
    names.items["Final Fantasy Resonance"][77000013] = "Potion x3"
    assert protocol.compact_hint(hint(1, 2), 1, names) == "Hint: your Potion x3 is at Tree (Bob's world)"
    own = {"receiving": 1, "item": {"item": 77000013, "location": 80201503, "player": 1}, "found": True}
    assert protocol.compact_hint(own, 1, names) == "Hint: your Potion x3 is at Chest (found)"
    theirs = {"receiving": 2, "item": {"item": 1, "location": 80201503, "player": 1}}
    assert protocol.compact_hint(theirs, 1, names) == "Hint: Chest has Bob's Sword"
    assert protocol.compact_hint({"receiving": 1}, 1, names) is None
