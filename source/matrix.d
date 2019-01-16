module matrix;

import core.stdc.stdlib : exit;
import std.conv : to;
import std.experimental.logger : fatal, info, warning;
import std.format : format;
import std.json : JSONException, JSONValue, parseJSON;
import std.net.curl : CurlException, get, HTTP, post, put;

import room;

static immutable string[string] NULL_PARAMS;

struct Config {
  string username;
  string password;
  string address;

  this (string filename) {
    import std.file : readText;
    this(parseJSON(readText(filename)));
  }

  this (string username, string password, string address) {
    this.username = username;
    this.password = password;
    this.address = address;
  }

  this (JSONValue config) {
    try {
      this.username = config["username"].str;
      this.password = config["password"].str;
      this.address = config["address"].str;
    } catch (JSONException e) {
      fatal("Could not read config from json configuration file");
      fatal("Message:\n%s", e.msg);
      exit(-1);
    }
  }

  string serverName () {
    import std.string : stripLeft;
    return this.address.stripLeft("https://");
  }
}

class Matrix {
private:
  string userID, accessToken, nextBatch;
  Room[] rooms;
  int txID;
  HTTP httpClient;

  string makeParamString (const string[string] params, string concat) {
    if (params.length == 0) {
      return "";
    }
    string result = concat;
    foreach (key, value; params) {
      result ~= "%s=%s&".format(key, value);
    }
    return result[0 .. $-1];
  }

  string buildUrl (string endpoint, const string[string] params = NULL_PARAMS,
                   string apiVersion = "unstable", string section = "client") {
    string url = "%s/_matrix/%s/%s/%s".format(
      this.config.address, section, apiVersion, endpoint
    );
    string concat = "?";

    if (this.accessToken.length) {
      url ~= "%saccess_token=%s".format(concat, this.accessToken);
      concat = "&";
    }

    string paramString = this.makeParamString(params, concat);
    if (paramString.length) {
      url ~= paramString;
    }

    return url;
  }

public:
  Config config;
  string currentRoom; // TODO probably a hack... unused?

  this (Config config) {
    this.config = config;
    this.httpClient = HTTP();
  }

  void login ()
  out (; this.accessToken.length > 0, "Login must set an access token")
  out (; this.userID.length > 0, "Login must set a user ID")
  do {
    string url = this.buildUrl("login");
    string data = `{
      "user": "%s", "password": "%s", "type": "m.login.password"
    }`.format(this.config.username, this.config.password);

    try {
      JSONValue response = parseJSON(post(url, data));
      this.accessToken = response["access_token"].str;
      this.userID = response["user_id"].str;
    } catch (JSONException e) {
      fatal("Error: Unable to login to the server");
      exit(-1);
    }

    info("Successfully logged in");
  }

  void join (string[] rooms ...)
  in (this.accessToken.length > 0, "Must be logged in first")
  out (; this.rooms.length > 0, "Must have joined at least one room")
  do {
    import std.string : translate;
    string[dchar] trTable = ['#' : "%23", ':' : "%3A"];
    foreach (room; rooms) {
      string tr = translate(room, trTable);
      try {
        JSONValue response = parseJSON(post(this.buildUrl("join/%s".format(tr)), `{}`));
        this.rooms ~= Room(response["room_id"].str);
        info("Successfully joined room: ", room);
      } catch (JSONException e) {
        warning("Warning: Failed to join the room: ", room);
      }
    }
    this.currentRoom = this.rooms[0].roomID;
  }

  JSONValue sync () {
    string url;
    if (this.nextBatch.length) {
      url = this.buildUrl("sync", ["since" : this.nextBatch]);
    } else {
      url = this.buildUrl("sync");
    }

    JSONValue response;
    try {
      response = parseJSON(get(url));
      this.nextBatch = response["next_batch"].str;
    } catch (JSONException e) {
      warning("Warning: Sync failed");
    } catch (CurlException e) {
      warning("Warning: Sync failed due to request failure");
    }

    return response;
  }

  void extractMessages(JSONValue data) {
    // TODO make a better return type
    foreach (room; this.rooms) {
      string id = room.roomID;
      try {
        auto roomData = data["rooms"]["join"];
        if (id in roomData) {
          JSONValue events = roomData[id]["timeline"]["events"];
          foreach (event; events.array) {
            if ("body" in event["content"]) {
              room.buffer ~= "<%s> %s".format(event["sender"].str, event["content"]["body"].str);
            }
          }
        }
      } catch (JSONException e) {
        continue;
      }
    }
  }
}
