import sys
from bs4 import BeautifulSoup

def load_html(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return BeautifulSoup(f, 'html.parser')
    except Exception as e:
        print(f"Error loading {filepath}: {e}")
        return None

def analyze_headers_and_packages(filepath):
    print(f"--- Analyzing {filepath} ---")
    soup = load_html(filepath)
    if not soup: return {}

    table = soup.find('table')
    if not table:
        print("No table found.")
        return {}

    data = {} # { Group: [ (Pkg, Vuln, Ver) ] }
    current_group = "Unknown"
    
    for tr in table.find_all('tr'):
        if 'class' in tr.attrs and 'group-header' in tr.attrs['class']:
            current_group = tr.get_text(strip=True)
            if current_group not in data:
                data[current_group] = []
        elif 'class' in tr.attrs and any(c.startswith('severity-') for c in tr.attrs['class']):
            cols = tr.find_all('td')
            if len(cols) >= 4:
                pkg = cols[0].get_text(strip=True)
                vuln = cols[1].get_text(strip=True)
                ver = cols[3].get_text(strip=True)
                data[current_group].append((pkg, vuln, ver))
    
    print(f"Groups found: {list(data.keys())}")
    return data

if __name__ == "__main__":
    file1 = "slingshotaerospace.jfrog.io_ironbank_ironbank_opensource_python_v3.10.15.html"
    file2 = "slingshotaerospace.jfrog.io_science-docker_talos-single-step_v1.2.12.html"
    
    data1 = analyze_headers_and_packages(file1)
    data2 = analyze_headers_and_packages(file2)
    
    # Find intersection of groups
    common_groups = set(data1.keys()) & set(data2.keys())
    print(f"\nCommon Groups: {common_groups}")
    
    # Check for common packages in common groups
    for group in common_groups:
        print(f"\nChecking group: '{group}'")
        set1 = set(data1[group])
        set2 = set(data2[group])
        
        common_items = set1 & set2
        only_in_1 = set1 - set2
        only_in_2 = set2 - set1
        
        print(f"  Total items in file1: {len(set1)}")
        print(f"  Total items in file2: {len(set2)}")
        print(f"  Exact matches: {len(common_items)}")
        print(f"  Only in file1: {len(only_in_1)}")
        print(f"  Only in file2: {len(only_in_2)}")
        
        # Sample mismatch if any
        if only_in_2:
            print("  Sample items ONLY in file2 (showing first 3):")
            for item in list(only_in_2)[:3]:
                # Try to find partially matching item in file1 (same pkg+vuln, diff ver)
                pkg, vuln, ver = item
                potential_match = [x for x in set1 if x[0] == pkg and x[1] == vuln]
                if potential_match:
                    print(f"    {item} (Mismatch? Found in file1 as: {potential_match})")
                else:
                    print(f"    {item} (New package/vuln)")







