# Warden - An assistant bot you don't entirely hate

Warden is a powerful AI-powered bot that can connect to various AI providers and social messaging platforms. Here is a list of the features it supports:
- Weather: Provides weather information for a given location
- Stats: Provides statistics about the group's conversations
- Word Cloud: Shows a word cloud of the most common words used in the group's conversations
- Group Management: Allows the bot to manage the group's conversations, including kicking and banning users

Supported Messaging Platforms:
- Telegram
- Matrix (comming soon)
- WhatsApp (comming soon)

Supported AI Providers:
- Anthropic
- Anything OpenAI-compatible

# How to Get Started
To get started with Warden, first clone the repository and install the dependencies:

```bash
git clone https://github.com/warden.git
zig build
```

Next, set the following environment variables in your `.env` file:
```
# Set either of the next two variables:
OPENAI_API_KEY=<your_openai_api_key>
# OR
ANTHROPIC_API_KEY=<your_anthropic_api_key>

export WARDEN_OPENAI_MODEL=<your_openai_model>
export WARDEN_OPENAI_API_KEY="<your_openai_api_key>"

# Messaging Platform:
TELEGRAM_TOKEN=<your_telegram_token>
```

Once all is set up, run:
```bash
./zig-out/bin/warden
```

# Questions or issues
You can ask questions or report issues in the issues section of this repository. I will try to respond as quickly as possible. Please note that this is a personal project and I may not always be able to respond immediately and support may be very limited.
