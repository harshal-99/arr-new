import urllib.request
import urllib.parse
import json
import sys

api_key = '104c566bb751410c95bb00d35ef78079'
folder_path = "/data/torrents/tv/[Anime Time] I'm Standing on a Million Lives (S01+02) [Dual Audio][BD][1080p][HEVC 10bit x265][AAC][Eng Sub]"

def get_manual_import():
    url = f'http://localhost:8989/api/v3/manualimport?folder={urllib.parse.quote(folder_path)}'
    req = urllib.request.Request(url, headers={'X-Api-Key': api_key})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode())

def main():
    data = get_manual_import()
    print(f"Total files found in manual scan: {len(data)}")
    for i, item in enumerate(data):
        path = item.get("path")
        series = item.get("series", {})
        series_title = series.get("title") if series else "None"
        episodes = item.get("episodes", [])
        ep_numbers = [ep.get("episodeNumber") for ep in episodes]
        season_number = episodes[0].get("seasonNumber") if episodes else "None"
        quality = item.get("quality", {}).get("quality", {}).get("name")
        print(f"[{i+1}] File: {path.split('/')[-1]}")
        print(f"    Detected Series: {series_title} (ID: {series.get('id') if series else 'None'})")
        print(f"    Season: {season_number}, Episode(s): {ep_numbers}")
        print(f"    Quality: {quality}")
        print("-" * 50)

if __name__ == "__main__":
    main()
