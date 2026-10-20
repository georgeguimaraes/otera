# Otera

Otera (お寺, "temple") renders [Jinja](https://jinja.palletsprojects.com) templates in pure Elixir. It has no native code and no dependencies.

The first goal is the chat templates of Hugging Face models. Otera renders them with the Python compatibility that `apply_chat_template` of transformers gives, and the tests compare each result with Python Jinja2 byte for byte.

The name follows Jinja. Jinja (神社) is a Japanese shrine, and a temple holds templates.

Otera is in development and is not on Hex yet.

## License

Apache-2.0
