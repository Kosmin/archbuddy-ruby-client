# frozen_string_literal: true

class OrdersController < ApplicationController
  def index
    Billing::Invoice.overdue   # app Const.method -> resolvable edge
  end
end
