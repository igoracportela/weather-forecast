class ForecastsController < ApplicationController
  NOT_FOUND = "We couldn't find that address. Try a full US street address or a 5-digit zip code.".freeze
  UNAVAILABLE = "Weather service unavailable, try again shortly.".freeze

  # GET /?address=... — a GET so a lookup can be bookmarked or shared.
  def show
    # A nested param (?address[]=...) is not an address; treat it as blank.
    @address = params[:address].is_a?(String) ? params[:address] : ""
    @forecast = Weather::Lookup.call(@address) if @address.present?
  rescue Weather::InvalidInput => e
    render_error e.message, :unprocessable_content
  rescue Weather::NotFound
    render_error NOT_FOUND, :unprocessable_content
  rescue Weather::ServiceError => e
    Rails.logger.warn("[forecast] upstream failure: #{e.message}")
    render_error UNAVAILABLE, :service_unavailable
  end

  private

  def render_error(message, status)
    @error = message
    render :show, status: status
  end
end
