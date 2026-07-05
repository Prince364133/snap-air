import requests
import json
import threading

class AIAssistant:
    def __init__(self, use_local=True, model_name="llama3"):
        self.use_local = use_local
        self.model_name = model_name
        self.ollama_url = "http://localhost:11434/api/generate"

    def process_command(self, text, callback=None):
        """Processes voice/text commands asynchronously."""
        def run():
            if self.use_local:
                response = self._query_ollama(text)
            else:
                response = "OpenAI API not configured."
            
            if callback:
                callback(response)
                
        thread = threading.Thread(target=run, daemon=True)
        thread.start()

    def _query_ollama(self, prompt):
        try:
            payload = {
                "model": self.model_name,
                "prompt": f"You are Snap Motion OS AI. The user said: '{prompt}'. Respond with a short action confirmation like 'Opening Notes' or 'Searching Web'.",
                "stream": False
            }
            response = requests.post(self.ollama_url, json=payload, timeout=5)
            if response.status_code == 200:
                data = response.json()
                return data.get("response", "Command understood.")
            else:
                return f"AI Error: {response.status_code}"
        except Exception as e:
            return "AI Engine unreachable. Is Ollama running?"

    # Mock Speech Recognition for demonstration
    def listen_for_wake_word(self, callback):
        def run():
            import time
            time.sleep(10) # Simulate 10 seconds passing before user speaks
            callback("Open my smart notes")
        
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
