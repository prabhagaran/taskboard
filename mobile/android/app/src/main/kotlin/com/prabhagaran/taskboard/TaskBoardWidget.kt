package com.prabhagaran.taskboard

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/** Home-screen widget listing tasks due today. The app supplies the text on each sync. */
class TaskBoardWidget : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val openApp = HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)
        appWidgetIds.forEach { id ->
            val views = RemoteViews(context.packageName, R.layout.taskboard_widget).apply {
                setTextViewText(R.id.widget_title, widgetData.getString("title", "Today"))
                setTextViewText(R.id.widget_lines, widgetData.getString("lines", "Open TaskBoard to sync"))
                setOnClickPendingIntent(R.id.widget_root, openApp)
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
