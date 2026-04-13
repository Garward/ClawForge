import json
import random
import requests
import os
from typing import Dict, List, Optional


class MemeGenerator:
    def __init__(self):
        self.imgflip_url = "https://api.imgflip.com/caption_image"
        self.username, self.password = self._load_credentials()
        
        # Popular meme templates with their Imgflip IDs
        self.templates = {
            "drake": "181913649",
            "this_is_fine": "55311130", 
            "success_kid": "61544",
            "picard_facepalm": "1509839",
            "confused_math": "4217262",
            "expanding_brain": "93895088",
            "surprised_pikachu": "155067746",
            "change_my_mind": "129242436",
            "batman_slap": "438680",
            "woman_yelling_cat": "188390779"
        }

    def _load_env_file(self, filepath: str) -> Dict[str, str]:
        """Load environment variables from a .env file"""
        env_vars = {}
        if os.path.exists(filepath):
            with open(filepath, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        key, value = line.split('=', 1)
                        # Remove quotes if present
                        value = value.strip('"\'')
                        env_vars[key] = value
        return env_vars

    def _load_credentials(self) -> tuple:
        """Load Imgflip API credentials from environment variables"""
        # Try environment variables first
        username = os.getenv('IMGFLIP_USERNAME')
        password = os.getenv('IMGFLIP_PASSWORD')

        # If not found, try loading from ClawForge .env then ~/.env
        if not username or not password:
            script_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            for env_path in [os.path.join(script_dir, '.env'), os.path.expanduser('~/.env')]:
                env_vars = self._load_env_file(env_path)
                username = username or env_vars.get('IMGFLIP_USERNAME')
                password = password or env_vars.get('IMGFLIP_PASSWORD')
                if username and password:
                    break

        return username, password

    def get_context_templates(self, context: str) -> List[str]:
        """Get suitable templates based on context/situation"""
        context = context.lower()
        
        context_map = {
            "success": ["success_kid", "drake"],
            "failure": ["this_is_fine", "picard_facepalm"],
            "debugging": ["this_is_fine", "confused_math", "picard_facepalm"],
            "confusion": ["confused_math", "surprised_pikachu"],
            "realization": ["expanding_brain", "surprised_pikachu"],
            "argument": ["change_my_mind", "batman_slap"],
            "comparison": ["drake", "expanding_brain"],
            "anger": ["woman_yelling_cat", "batman_slap"],
            "testing": ["success_kid", "this_is_fine"]
        }
        
        # Find matching contexts
        for ctx, templates in context_map.items():
            if ctx in context:
                return templates
        
        # Default fallback
        return ["drake", "this_is_fine", "success_kid"]

    def generate_captions(self, template: str, context: str, mood: Optional[str]) -> tuple:
        """Generate appropriate captions based on template and context"""
        
        if template == "drake":
            if "debug" in context.lower():
                return "Print statements everywhere", "Using a proper debugger"
            elif "test" in context.lower():
                return "Works on my machine", "Comprehensive test suite"
            else:
                return "Old way", "New way"
        
        elif template == "this_is_fine":
            if "debug" in context.lower():
                return "Everything is working", "500 console errors"
            elif "deploy" in context.lower():
                return "Production is stable", "Error rate: 90%"
            else:
                return "This is fine", "Everything is on fire"
        
        elif template == "success_kid":
            if "deploy" in context.lower():
                return "Deployed to production", "No rollbacks needed"
            elif "test" in context.lower():
                return "Code compiled", "On first try"
            else:
                return "Task completed", "Successfully"
        
        elif template == "picard_facepalm":
            if "bug" in context.lower():
                return "Found the bug", "It was a typo"
            else:
                return "When you realize", "The obvious mistake"
        
        elif template == "confused_math":
            return "Documentation says", "Code actually does"
        
        elif template == "expanding_brain":
            return "Basic solution", "Galaxy brain approach"
        
        elif template == "surprised_pikachu":
            if "break" in context.lower():
                return "Changed one line", "Entire system breaks"
            else:
                return "Expected behavior", "Actual result"
        
        elif template == "change_my_mind":
            return f"{context} is overrated", "Change my mind"
        
        elif template == "batman_slap":
            return "We should use PHP", "Stop right there"
        
        elif template == "woman_yelling_cat":
            return "Me at my code", "Code working perfectly"
        
        # Mood-based fallbacks
        if mood:
            if mood == "excitement":
                return "Before", "After upgrade"
            elif mood == "frustration":
                return "Expectation", "Reality"  
            elif mood == "confusion":
                return "Documentation", "Actual behavior"
            else:
                return "Before", "After"
        else:
            return "Before", "After"
    
    def generate_meme(self, template: Optional[str] = None, context: str = "", 
                     top_text: Optional[str] = None, bottom_text: Optional[str] = None,
                     mood: Optional[str] = None) -> Dict:
        """Generate a meme image using Imgflip API"""
        
        try:
            # Check credentials
            if not self.username or not self.password:
                return {
                    "success": False,
                    "error": "Imgflip credentials not found. Set IMGFLIP_USERNAME and IMGFLIP_PASSWORD in ClawForge/.env"
                }
            
            # Select template
            if not template:
                suitable_templates = self.get_context_templates(context)
                template = random.choice(suitable_templates)
            
            # Validate template exists
            if template not in self.templates:
                available = list(self.templates.keys())
                return {
                    "success": False,
                    "error": f"Unknown template '{template}'. Available: {', '.join(available)}"
                }
            
            template_id = self.templates[template]
            
            # Generate captions if not provided
            if not top_text or not bottom_text:
                auto_top, auto_bottom = self.generate_captions(template, context, mood)
                top_text = top_text or auto_top
                bottom_text = bottom_text or auto_bottom
            
            # Make API request
            payload = {
                'template_id': template_id,
                'text0': top_text,
                'text1': bottom_text,
                'username': self.username,
                'password': self.password
            }
            
            response = requests.post(self.imgflip_url, data=payload, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                if data.get('success'):
                    return {
                        "success": True,
                        "url": data['data']['url'],
                        "template": template,
                        "top_text": top_text,
                        "bottom_text": bottom_text,
                        "context": context
                    }
                else:
                    return {
                        "success": False,
                        "error": data.get('error_message', 'Unknown API error')
                    }
            else:
                return {
                    "success": False, 
                    "error": f"HTTP {response.status_code}: {response.text}"
                }
                
        except requests.RequestException as e:
            return {
                "success": False,
                "error": f"Network error: {str(e)}"
            }
        except Exception as e:
            return {
                "success": False,
                "error": f"Unexpected error: {str(e)}"
            }

def meme_generate(template: Optional[str] = None, context: str = "", 
                 top_text: Optional[str] = None, bottom_text: Optional[str] = None,
                 mood: Optional[str] = None) -> Dict:
    """
    Generate a contextually relevant meme
    
    Args:
        template: Specific meme template to use (optional)
        context: Description of current situation for auto-selection
        top_text: Custom top text (optional)
        bottom_text: Custom bottom text (optional)  
        mood: Mood/tone (success, failure, confusion, etc.)
    
    Returns:
        Dict with success status, meme URL, and metadata
    """
    generator = MemeGenerator()
    return generator.generate_meme(template, context, top_text, bottom_text, mood)

def list_templates() -> List[str]:
    """List all available meme templates"""
    generator = MemeGenerator()
    return list(generator.templates.keys())

def get_template_contexts() -> Dict[str, List[str]]:
    """Get mapping of contexts to suggested templates"""
    generator = MemeGenerator()
    return generator.context_map

if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: python meme_tool.py '{\"context\":\"debugging\"}'")
        sys.exit(1)

    # Special commands
    if sys.argv[1] == "list":
        print("Available templates:", ", ".join(list_templates()))
        sys.exit(0)

    if sys.argv[1] == "contexts":
        for context, templates in get_template_contexts().items():
            print(f"  {context}: {', '.join(templates)}")
        sys.exit(0)

    # JSON input mode (used by ClawForge tool system)
    try:
        params = json.loads(sys.argv[1])
    except json.JSONDecodeError:
        # Fallback: treat as context string
        params = {"context": sys.argv[1]}

    result = meme_generate(
        template=params.get("template"),
        context=params.get("context", ""),
        top_text=params.get("top_text"),
        bottom_text=params.get("bottom_text"),
        mood=params.get("mood"),
    )

    if result.get("success"):
        # Output just the URL for clean integration
        print(result["url"])
    else:
        print(f"Error: {result.get('error', 'Unknown error')}")
        sys.exit(1)