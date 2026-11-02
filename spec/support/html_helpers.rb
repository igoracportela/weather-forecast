# Parsed response body for request specs: `html.css(".zip")`.
module HtmlHelpers
  def html
    Nokogiri::HTML5(response.body)
  end
end

RSpec.configure { |config| config.include HtmlHelpers, type: :request }
