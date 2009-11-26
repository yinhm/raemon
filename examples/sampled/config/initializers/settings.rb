require 'yaml'
SETTINGS = YAML.load(File.read(RAEMON_ROOT + "/config/settings.yml"))[RAEMON_ENV]
