package com.prabhagaran.taskboard

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider

/** Home-screen widget with a scrolling list of open tasks. The app supplies the text on each sync. */
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
                setTextViewText(R.id.widget_title, widgetData.getString("title", "To Do"))
                setRemoteAdapter(R.id.widget_list, Intent(context, TaskBoardWidgetService::class.java))
                setEmptyView(R.id.widget_list, R.id.widget_empty)
                setTextViewText(
                    R.id.widget_empty,
                    if (widgetData.contains("lines")) "No open tasks" else "Open TaskBoard to sync",
                )
                setOnClickPendingIntent(R.id.widget_root, openApp)
                // List rows swallow taps, so they need a template of their own.
                setPendingIntentTemplate(R.id.widget_list, rowTemplate(context))
            }
            appWidgetManager.updateAppWidget(id, views)
        }
        appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetIds, R.id.widget_list)
    }

    private fun rowTemplate(context: Context): PendingIntent {
        val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        return PendingIntent.getActivity(
            context,
            1,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or mutable,
        )
    }
}

/** Supplies the widget's rows from the lines the app saved. */
class TaskBoardWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = Rows(applicationContext)

    private class Rows(private val context: Context) : RemoteViewsFactory {
        private var lines = emptyList<String>()

        override fun onDataSetChanged() {
            lines = HomeWidgetPlugin.getData(context).getString("lines", "")
                .orEmpty()
                .split('\n')
                .filter { it.isNotEmpty() }
        }

        override fun getViewAt(position: Int) =
            RemoteViews(context.packageName, R.layout.taskboard_widget_item).apply {
                setTextViewText(R.id.widget_item, lines.getOrElse(position) { "" })
                setOnClickFillInIntent(R.id.widget_item, Intent())
            }

        override fun getCount() = lines.size
        override fun getViewTypeCount() = 1
        override fun getItemId(position: Int) = position.toLong()
        override fun hasStableIds() = false
        override fun getLoadingView(): RemoteViews? = null
        override fun onCreate() {}
        override fun onDestroy() {}
    }
}
