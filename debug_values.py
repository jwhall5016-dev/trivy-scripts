import sys
from bs4 import BeautifulSoup

def load_html(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        return BeautifulSoup(f, 'html.parser')

def inspect_file(filepath, target_cve):
    print(f"--- Inspecting {filepath} for {target_cve} ---")
    try:
        soup = load_html(filepath)
    except FileNotFoundError:
        print(f"Error: File not found: {filepath}")
        return

    table = soup.find('table')
    if not table:
        print("No table found in file.")
        return

    current_group = "Unknown"
    
    found = False
    for tr in table.find_all('tr'):
        if 'class' in tr.attrs and 'group-header' in tr.attrs['class']:
            current_group = tr.get_text(strip=True)
        elif 'class' in tr.attrs and any(c.startswith('severity-') for c in tr.attrs['class']):
            cols = tr.find_all('td')
            if len(cols) >= 4:
                pkg = cols[0].get_text(strip=True)
                vuln = cols[1].get_text(strip=True)
                ver = cols[3].get_text(strip=True)
                
                if vuln == target_cve:
                    print(f"FOUND: Group='{current_group}', Pkg='{pkg}', Vuln='{vuln}', Ver='{ver}'")
                    print(f"RAW Group: {repr(current_group)}")
                    print(f"RAW Pkg: {repr(pkg)}")
                    print(f"RAW Vuln: {repr(vuln)}")
                    print(f"RAW Ver: {repr(ver)}")
                    found = True
    
    if not found:
        print("Target CVE NOT FOUND in this file.")

if __name__ == "__main__":
    # Check for CVE-2025-13836 which was flagged as NEW
    cve = "CVE-2025-13836"
    
    # Update paths to the files in the main directory as requested
    file1 = "slingshotaerospace.jfrog.io_science-docker_talos-single-step_v1.2.11.html"
    file2 = "slingshotaerospace.jfrog.io_science-docker_talos-single-step_v1.2.12.html"
    
    inspect_file(file1, cve)
    inspect_file(file2, cve)
