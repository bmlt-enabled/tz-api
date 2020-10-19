import json
import os
import time
import urllib3


nope_response = {
    "statusCode": 403,
    "headers": {"content-type": "application/xml"},
    "body": json.dumps("<blah><status>NOPE</status></blah>")
}


API_KEY = os.environ.get("GOOGLE_API_KEY")


def handler(event, context):
    path = event.get("path")
    if not path.startswith("/bmlt"):
        print("bad path")
        return nope_response

    params = event.get("queryStringParameters")
    if not params:
        print("no params")
        return nope_response

    location = params.get("location")
    if not location:
        print("no location")
        return nope_response

    http = urllib3.PoolManager()

    print(f"location: {location}")
    latitude, longitude = get_coordinates(http, location)
    if not latitude or not longitude:
        print("bad latitude and longitude")
        return nope_response

    print(f"latitude {latitude}")
    print(f"longitude {longitude}")
    r = http.request(
        "GET",
        "https://maps.googleapis.com/maps/api/timezone/xml",
        fields={
            "location": f"{latitude},{longitude}",
            "timestamp": str(int(time.time())),
            "key": API_KEY
        }
    )

    return {
        "statusCode": r.status,
        "headers": {"content-type": "application/xml"},
        "body": r.data.decode()
    }


def get_time_zone(http, latitude, longitude):
    pass


def get_coordinates(http, location):
    r = http.request(
        "GET",
        "https://maps.googleapis.com/maps/api/geocode/json",
        fields={
            "address": location,
            "key": API_KEY
        }
    )

    r = json.loads(r.data.decode())

    status = r.get("status")
    if status != "OK":
        print("not ok")
        return None, None

    results = r.get("results")
    if not results:
        print("bad results")
        return None, None

    location = results[0]["geometry"]["location"]
    if not location:
        print("bad location")
        return None, None

    return location.get("lat"), location.get("lng")
