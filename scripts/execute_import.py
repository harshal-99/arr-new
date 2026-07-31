import urllib.request
import urllib.parse
import json
import re
import sys

api_key = '104c566bb751410c95bb00d35ef78079'
series_id = 64
folder_path = "/data/torrents/tv/[Anime Time] I'm Standing on a Million Lives (S01+02) [Dual Audio][BD][1080p][HEVC 10bit x265][AAC][Eng Sub]"

def get_episodes(series_id):
    url = f'http://localhost:8989/api/v3/episode?seriesId={series_id}'
    req = urllib.request.Request(url, headers={'X-Api-Key': api_key})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode())

def get_manual_import(folder):
    url = f'http://localhost:8989/api/v3/manualimport?folder={urllib.parse.quote(folder)}'
    req = urllib.request.Request(url, headers={'X-Api-Key': api_key})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode())

def post_command(payload):
    url = 'http://localhost:8989/api/v3/command'
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(url, data=data, headers={
        'X-Api-Key': api_key,
        'Content-Type': 'application/json'
    })
    try:
        with urllib.request.urlopen(req) as r:
            res = json.loads(r.read().decode())
            return res
    except urllib.error.HTTPError as e:
        print("HTTP Error:", e.code, e.read().decode())
        sys.exit(1)

def main():
    print("Fetching episodes of series 64...")
    episodes = get_episodes(series_id)
    # Create mapping of (season, episode) -> episode_id
    ep_map = {}
    for ep in episodes:
        ep_map[(ep['seasonNumber'], ep['episodeNumber'])] = ep['id']
    
    print("Fetching manual import files...")
    import_items = get_manual_import(folder_path)
    print(f"Found {len(import_items)} files to scan.")
    
    files_payload = []
    
    for item in import_items:
        path = item.get('path')
        filename = path.split('/')[-1]
        parent_dir = path.split('/')[-2]
        
        # Season
        season_match = re.search(r'Season\s+(\d+)', parent_dir, re.IGNORECASE)
        if season_match:
            season_num = int(season_match.group(1))
        else:
            s_match = re.search(r'S(\d+)', filename, re.IGNORECASE)
            if s_match:
                season_num = int(s_match.group(1))
            else:
                season_num = 1
                
        # Episode
        ep_match = re.search(r'(?:S\d+\s*-\s*|\s+-\s+)(\d+)', filename, re.IGNORECASE)
        if ep_match:
            episode_num = int(ep_match.group(1))
        else:
            # Fallback to last number in filename before .mkv
            name_no_ext = filename.rsplit('.', 1)[0]
            nums = re.findall(r'\d+', name_no_ext)
            if nums:
                episode_num = int(nums[-1])
            else:
                print(f"Warning: Could not parse episode for file: {filename}")
                continue
        
        # Look up episode ID
        ep_key = (season_num, episode_num)
        if ep_key not in ep_map:
            print(f"Warning: Episode S{season_num:02d}E{episode_num:02d} not found in Sonarr series episodes list!")
            continue
            
        ep_id = ep_map[ep_key]
        
        # Build the payload object by cloning/modifying the existing item
        modified_item = dict(item)
        modified_item['seriesId'] = series_id
        modified_item['episodeIds'] = [ep_id]
        modified_item['seasonNumber'] = season_num
        modified_item['rejections'] = []
        
        files_payload.append(modified_item)
        print(f"Mapped: {filename} -> Season {season_num}, Episode {episode_num} (Episode ID: {ep_id})")

    if not files_payload:
        print("No files mapped successfully. Aborting.")
        return
        
    print(f"Sending ManualImport command to Sonarr for {len(files_payload)} files...")
    
    command_payload = {
        "name": "ManualImport",
        "importMode": "copy", # "copy" means hardlink if global setting enabled
        "files": files_payload
    }
    
    result = post_command(command_payload)
    print("Command response:")
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
