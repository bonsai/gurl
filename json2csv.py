import pandas as pd
import json

# Read the JSON file
file_path = '/home/vons/.config/gemini/conversation_history.json'

# Read the JSON file
with open(file_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

# Convert to DataFrame, focusing on the main fields
df = pd.DataFrame([
    {
        'timestamp': item.get('timestamp', ''),
        'model': item.get('model', ''),
        'prompt': item.get('prompt', ''),
        'text_response': item.get('text_response', '')
    }
    for item in data
])

# Save to CSV
output_path = 'conversation_history.csv'
df.to_csv(output_path, index=False, encoding='utf-8')
print(f"Data successfully saved to {output_path}")
print(f"Total conversations processed: {len(df)}")
