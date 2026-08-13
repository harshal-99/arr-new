#!/usr/bin/env python3
import subprocess
import time
import os
import sys

# Define constants
TOTAL_SIZE_BYTES = 992928826682

def get_nas_info():
    # SSH command to get size and screen status
    cmd = "sshpass -p 'YOUR_SSH_PASSWORD' ssh -o StrictHostKeyChecking=no harshal@192.168.0.236 " \
          "\"du -s /share/CACHEDEV1_DATA/data && (screen -ls | grep -q nas_copy && echo 'RUNNING' || echo 'STOPPED')\""
    try:
        res = subprocess.check_output(cmd, shell=True).decode('utf-8').strip().split('\n')
        cleaned_res = [line for line in res if not line.startswith("Could not chdir") and not line.startswith("Warning:")]
        if len(cleaned_res) >= 2:
            size_kb = int(cleaned_res[0].split()[0])
            status = cleaned_res[1]
        elif len(cleaned_res) == 1:
            size_kb = int(cleaned_res[0].split()[0])
            status = "STOPPED"
        else:
            raise ValueError("Empty response")
        return size_kb, status
    except Exception as e:
        print(f"Error connecting to NAS: {e}")
        sys.exit(1)

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    completed_file = os.path.join(script_dir, "transfer_completed.txt")
    
    # If already completed, do nothing
    if os.path.exists(completed_file):
        print("Transfer was already marked as completed.")
        sys.exit(0)
        
    size_kb, status = get_nas_info()
    copied_bytes = size_kb * 1024
    
    # If the screen session is stopped, check if we copied most of the data
    if status == "STOPPED":
        percent = (copied_bytes / TOTAL_SIZE_BYTES) * 100
        
        if percent >= 95.0:
            print("Copy session is gone and progress is >= 95%. Starting Docker services...")
            # Run systemctl --user start arr-stack.service
            try:
                start_cmd = "systemctl --user start arr-stack.service"
                subprocess.check_call(start_cmd, shell=True)
                print("Docker services successfully started!")
                
                # Mark as completed
                with open(completed_file, 'w') as f:
                    f.write(f"Completed at {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
                
                print("### Copy Complete & Services Started!")
                print(f"* **Total Copied**: {copied_bytes / (1024**3):.2f} GB")
                print("* **Status**: Docker services are now UP and RUNNING.")
            except Exception as e:
                print(f"Error starting Docker services: {e}")
        else:
            print(f"Copy session is stopped, but progress is only {percent:.2f}%. Please check for errors in the QNAP log.")
    else:
        # Transfer is still running. Call the progress check script to print progress.
        progress_script = os.path.join(script_dir, "check_copy_progress.py")
        if os.path.exists(progress_script):
            subprocess.check_call(progress_script, shell=True)
        else:
            print("Transfer is still running.")

if __name__ == "__main__":
    main()
